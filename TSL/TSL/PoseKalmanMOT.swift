//
//  PoseKalmanMOT.swift
//  TSL
//
//  Seguimiento multi-persona (MOT) con filtro de Kalman por articulación:
//  predicción entre frames y durante oclusiones / puntos de baja confianza.
//

import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Articulaciones que actualizamos con Kalman (orden fijo, sin depender de `CaseIterable` del SDK).
private let allPoseJoints: [VNHumanBodyPoseObservation.JointName] = [
    .nose, .leftEye, .rightEye, .leftEar, .rightEar,
    .neck,
    .leftShoulder, .rightShoulder,
    .leftElbow, .rightElbow,
    .leftWrist, .rightWrist,
    .leftHip, .rightHip,
    .root,
    .leftKnee, .rightKnee,
    .leftAnkle, .rightAnkle
]

// MARK: - Kalman 2D (modelo de velocidad constante)

/// Estado [px, py, vx, vy] en espacio normalizado de Vision (mismo que `recognizedPoint`).
private struct KalmanFilter2D {
    private var x: [Double] = [0, 0, 0, 0]
    private var P: [[Double]]
    private var initialized = false

    /// Ruido de proceso (aceleración no modelada).
    private let qPos: Double
    private let qVel: Double
    /// Ruido de medición (coordenadas normalizadas).
    private let rMeas: Double

    init(qPos: Double = 2e-4, qVel: Double = 5e-3, rMeas: Double = 4e-4) {
        self.qPos = qPos
        self.qVel = qVel
        self.rMeas = rMeas
        P = (0..<4).map { i in (0..<4).map { j in i == j ? (i < 2 ? 1.0 : 10.0) : 0.0 } }
    }

    mutating func predict(dt: Double) {
        guard initialized else { return }
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt3 * dt

        let f: [[Double]] = [
            [1, 0, dt, 0],
            [0, 1, 0, dt],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ]
        x = matVecMul(f, x)

        let q00 = qPos * (dt4 / 4.0)
        let q02 = qPos * (dt3 / 2.0)
        let q22 = qPos * dt2
        let q33 = qVel * dt2

        let Q: [[Double]] = [
            [q00, 0, q02, 0],
            [0, q00, 0, q02],
            [q02, 0, q22, 0],
            [0, q02, 0, q33]
        ]
        let FPFT = matMul(matMul(f, P), transpose(f))
        P = matAdd(FPFT, Q)
    }

    mutating func update(measurement mx: Double, _ my: Double) {
        let z = [mx, my]
        if !initialized {
            x = [mx, my, 0, 0]
            P = [
                [1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 10, 0],
                [0, 0, 0, 10]
            ]
            initialized = true
            return
        }

        let H: [[Double]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0]
        ]
        let R: [[Double]] = [
            [rMeas, 0],
            [0, rMeas]
        ]

        let Hx = matVecMul(H, x)
        var y = [Double](repeating: 0, count: 2)
        for i in 0..<2 { y[i] = z[i] - Hx[i] }

        let HP = matMul(H, P)
        let HPT = matMul(HP, transpose(H))
        let S = matAdd(HPT, R)
        let Sinv = invert2x2(S) ?? [[1.0 / rMeas, 0], [0, 1.0 / rMeas]]

        let PHT = matMul(P, transpose(H))
        let K = matMul(PHT, Sinv)

        let Ky = matVecMul(K, y)
        for i in 0..<4 { x[i] += Ky[i] }

        let KH = matMul(K, H)
        let I = identity4()
        let IKH = matSub(I, KH)
        P = matMul(IKH, P)
    }

    func position() -> CGPoint {
        CGPoint(x: x[0], y: x[1])
    }

    var hasEstimate: Bool { initialized }
}

// MARK: - Álgebra mínima (4×4 y 2×2)

private func identity4() -> [[Double]] {
    (0..<4).map { i in (0..<4).map { j in i == j ? 1.0 : 0.0 } }
}

private func transpose(_ a: [[Double]]) -> [[Double]] {
    guard !a.isEmpty else { return a }
    let r = a.count, c = a[0].count
    return (0..<c).map { j in (0..<r).map { i in a[i][j] } }
}

private func matVecMul(_ a: [[Double]], _ v: [Double]) -> [Double] {
    a.map { row in zip(row, v).map(*).reduce(0, +) }
}

private func matMul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
    let ar = a.count, ac = a[0].count, bc = b[0].count
    var out = [[Double]](repeating: [Double](repeating: 0, count: bc), count: ar)
    for i in 0..<ar {
        for j in 0..<bc {
            var s = 0.0
            for k in 0..<ac { s += a[i][k] * b[k][j] }
            out[i][j] = s
        }
    }
    return out
}

private func matAdd(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
    zip(a, b).map { zip($0, $1).map(+) }
}

private func matSub(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
    zip(a, b).map { zip($0, $1).map(-) }
}

private func invert2x2(_ m: [[Double]]) -> [[Double]]? {
    let a = m[0][0], b = m[0][1], c = m[1][0], d = m[1][1]
    let det = a * d - b * c
    guard abs(det) > 1e-12 else { return nil }
    return [
        [d / det, -b / det],
        [-c / det, a / det]
    ]
}

// MARK: - Medición de pose

struct PoseJointSample {
    let location: CGPoint
    let confidence: Float
}

// MARK: - Pista corporal (MOT + Kalman por articulación)

private final class BodyPoseTrack {
    let id: Int
    private var filters: [VNHumanBodyPoseObservation.JointName: KalmanFilter2D] = [:]
    var missedFrames: Int = 0

    init(id: Int) {
        self.id = id
    }

    func predict(dt: Double) {
        for joint in Array(filters.keys) {
            guard var f = filters[joint] else { continue }
            f.predict(dt: dt)
            filters[joint] = f
        }
    }

    func update(from observation: VNHumanBodyPoseObservation, confidenceThreshold: Float) {
        missedFrames = 0
        for joint in allPoseJoints {
            guard let p = try? observation.recognizedPoint(joint) else { continue }
            if p.confidence < confidenceThreshold {
                continue
            }
            let lx = Double(p.location.x)
            let ly = Double(p.location.y)
            if filters[joint] == nil {
                filters[joint] = KalmanFilter2D()
            }
            var f = filters[joint]!
            f.update(measurement: lx, ly)
            filters[joint] = f
        }
    }

    /// Centroide en espacio Vision (para asociación entre frames).
    func associationCentroid() -> CGPoint? {
        let keys: [VNHumanBodyPoseObservation.JointName] = [
            .root, .leftHip, .rightHip, .leftShoulder, .rightShoulder, .neck, .nose
        ]
        var sx = 0.0, sy = 0.0, n = 0.0
        for k in keys {
            guard let f = filters[k], f.hasEstimate else { continue }
            let c = f.position()
            sx += Double(c.x)
            sy += Double(c.y)
            n += 1
        }
        guard n > 0 else { return nil }
        return CGPoint(x: sx / n, y: sy / n)
    }

    /// Mapa articulación → muestra suavizada (Kalman) en coords Vision.
    func smoothedJoints() -> [VNHumanBodyPoseObservation.JointName: PoseJointSample] {
        var out: [VNHumanBodyPoseObservation.JointName: PoseJointSample] = [:]
        for (joint, f) in filters where f.hasEstimate {
            let pt = f.position()
            out[joint] = PoseJointSample(location: pt, confidence: 1.0)
        }
        return out
    }

    /// Solo predice (p. ej. cuerpo no detectado este frame).
    func markMissed() {
        missedFrames += 1
    }
}

// MARK: - Rastreador multi-objeto

final class MultiBodyPoseKalmanTracker {
    private var tracks: [BodyPoseTrack] = []
    private var nextId = 1
    private var lastTimestamp: CFTimeInterval?
    /// Asociación: distancia máxima en espacio normalizado entre centroides.
    private let associationThreshold: CGFloat = 0.22
    private let maxMissedFrames = 18
    private let maxTracks = 6
    private let jointConfidenceForUpdate: Float = 0.22

    func reset() {
        tracks.removeAll()
        nextId = 1
        lastTimestamp = nil
    }

    /// Procesa todas las observaciones del frame y devuelve mapas suavizados por pista.
    func update(
        observations: [VNHumanBodyPoseObservation],
        sampleBuffer: CMSampleBuffer
    ) -> [[VNHumanBodyPoseObservation.JointName: PoseJointSample]] {
        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let dt: Double
        if let last = lastTimestamp, now > last {
            dt = min(now - last, 0.25)
        } else {
            dt = 1.0 / 30.0
        }
        lastTimestamp = now

        for t in tracks {
            t.predict(dt: dt)
        }

        let obsCentroids: [CGPoint] = observations.map { centroidForAssociation($0) }
        var matchedTrack = Set<Int>()
        var matchedObs = Set<Int>()

        var pairs: [(cost: CGFloat, ti: Int, oi: Int)] = []
        for (ti, track) in tracks.enumerated() {
            guard let pc = track.associationCentroid() else { continue }
            for (oi, oc) in obsCentroids.enumerated() {
                let dx = pc.x - oc.x, dy = pc.y - oc.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < associationThreshold {
                    pairs.append((dist, ti, oi))
                }
            }
        }
        pairs.sort { $0.cost < $1.cost }
        for p in pairs {
            if matchedTrack.contains(p.ti) || matchedObs.contains(p.oi) { continue }
            matchedTrack.insert(p.ti)
            matchedObs.insert(p.oi)
            tracks[p.ti].update(from: observations[p.oi], confidenceThreshold: jointConfidenceForUpdate)
        }

        for (oi, obs) in observations.enumerated() where !matchedObs.contains(oi) {
            guard tracks.count < maxTracks else { break }
            let t = BodyPoseTrack(id: nextId)
            nextId += 1
            t.update(from: obs, confidenceThreshold: jointConfidenceForUpdate)
            tracks.append(t)
        }

        for (ti, _) in tracks.enumerated() where !matchedTrack.contains(ti) {
            tracks[ti].markMissed()
        }

        tracks.removeAll { $0.missedFrames > maxMissedFrames }

        return tracks.map { $0.smoothedJoints() }
    }
}

// MARK: - Utilidades públicas

func centroidForAssociation(_ observation: VNHumanBodyPoseObservation) -> CGPoint {
    let keys: [VNHumanBodyPoseObservation.JointName] = [
        .root, .leftHip, .rightHip, .leftShoulder, .rightShoulder, .neck, .nose
    ]
    var sx = 0.0, sy = 0.0, n = 0.0
    for k in keys {
        guard let p = try? observation.recognizedPoint(k), p.confidence > 0.2 else { continue }
        sx += Double(p.location.x)
        sy += Double(p.location.y)
        n += 1
    }
    if n == 0 {
        return CGPoint(x: 0.5, y: 0.5)
    }
    return CGPoint(x: sx / n, y: sy / n)
}

/// Pista más centrada en la imagen (prioridad UI / postura).
func primaryTrackIndex(_ tracks: [[VNHumanBodyPoseObservation.JointName: PoseJointSample]]) -> Int {
    guard !tracks.isEmpty else { return 0 }
    let center = CGPoint(x: 0.5, y: 0.5)
    var best = 0
    var bestDist = CGFloat.greatestFiniteMagnitude
    for (i, joints) in tracks.enumerated() {
        let pts = joints.values.map(\.location)
        guard !pts.isEmpty else { continue }
        let mx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        let my = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        let c = CGPoint(x: mx, y: my)
        let d = hypot(c.x - center.x, c.y - center.y)
        if d < bestDist {
            bestDist = d
            best = i
        }
    }
    return best
}
