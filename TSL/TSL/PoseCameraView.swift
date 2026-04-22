//
//  PoseCameraView.swift
//  TSL
//
//  Cámara en vivo + pose corporal con Vision (API nativa Apple, equivalente a uso típico de MediaPipe pose en 2D).
//

import AVFoundation
import Combine
import SwiftUI
import UIKit
import Vision

// MARK: - Estado de postura y puente de logs

enum PostureState: Equatable {
    case none
    case good
    case bad
}

final class PoseCameraBridge: ObservableObject {
    @Published var postureState: PostureState = .none
    @Published var logs: [String] = []

    private let maxLogs = 300

    func appendLog(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(ts)] \(line)"
        logs.insert(entry, at: 0)
        if logs.count > maxLogs {
            logs.removeLast()
        }
    }

    func setPosture(_ state: PostureState) {
        postureState = state
    }
}

// MARK: - Heurística “joroba” / cabeza adelantada (coordenadas normalizadas Vision)

private enum PostureAnalyzer {
    /// True si la pose sugiere joroba o cabeza adelantada (vista frontal aproximada).
    /// Usa articulaciones ya suavizadas (p. ej. salida Kalman / MOT).
    static func isHunchedOrPoorPosture(
        joints: [VNHumanBodyPoseObservation.JointName: PoseJointSample]
    ) -> Bool {
        guard let nose = joints[.nose], nose.confidence > 0.28,
              let ls = joints[.leftShoulder], ls.confidence > 0.22,
              let rs = joints[.rightShoulder], rs.confidence > 0.22
        else { return false }

        let shoulderMidX = (ls.location.x + rs.location.x) / 2
        let shoulderMidY = (ls.location.y + rs.location.y) / 2

        let forwardHead = abs(nose.location.x - shoulderMidX)
        if forwardHead > 0.10 {
            return true
        }

        if abs(ls.location.y - rs.location.y) > 0.09 {
            return true
        }

        if let lh = joints[.leftHip], let rh = joints[.rightHip],
           lh.confidence > 0.22, rh.confidence > 0.22 {
            let hipMidY = (lh.location.y + rh.location.y) / 2
            if shoulderMidY - hipMidY < 0.07 {
                return true
            }
        }

        return false
    }
}

// MARK: - SwiftUI

struct PoseCameraView: View {
    @Binding var isPresented: Bool
    @StateObject private var bridge = PoseCameraBridge()
    @State private var showLogPanel = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PoseCameraRepresentable(bridge: bridge, isPresented: $isPresented)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }

                    Button {
                        showLogPanel = true
                    } label: {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .accessibilityLabel("Registro de postura")
                }
                .padding(.leading, 20)
                .padding(.top, 16)

                Spacer()
            }

            VStack {
                Spacer()
                Text("Colócate frente a la cámara — campana: registro — arriba: semáforo y cambio de cámara")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 36)
            }
        }
        .sheet(isPresented: $showLogPanel) {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(bridge.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Registro de postura")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cerrar") { showLogPanel = false }
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            guard bridge.postureState == .good else { return }
            bridge.appendLog("Postura correcta")
        }
    }
}

// MARK: - UIViewControllerRepresentable

private struct PoseCameraRepresentable: UIViewControllerRepresentable {
    @ObservedObject var bridge: PoseCameraBridge
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> PoseCameraViewController {
        let vc = PoseCameraViewController()
        vc.bridge = bridge
        vc.onDismissRequest = { isPresented = false }
        return vc
    }

    func updateUIViewController(_ uiViewController: PoseCameraViewController, context: Context) {}
}

// MARK: - Conexiones del esqueleto

private let bodyJointConnections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
    (.neck, .nose),
    (.leftShoulder, .neck),
    (.rightShoulder, .neck),
    (.leftShoulder, .rightShoulder),
    (.leftShoulder, .leftElbow),
    (.leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow),
    (.rightElbow, .rightWrist),
    (.leftShoulder, .leftHip),
    (.rightShoulder, .rightHip),
    (.leftHip, .rightHip),
    (.leftHip, .leftKnee),
    (.leftKnee, .leftAnkle),
    (.rightHip, .rightKnee),
    (.rightKnee, .rightAnkle)
]

// MARK: - Vista de cámara + Vision

private final class PoseCameraViewController: UIViewController {
    var onDismissRequest: (() -> Void)?
    weak var bridge: PoseCameraBridge?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tsl.camera.session")
    private let visionQueue = DispatchQueue(label: "tsl.vision.pose")

    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let overlayView = PoseOverlayView()
    private let trafficLightView = TrafficLightIndicatorView()
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let poseTracker = MultiBodyPoseKalmanTracker()

    private var isProcessingFrame = false
    private var cameraPosition: AVCaptureDevice.Position = .front
    private var lastLoggedBadTransition = false

    private lazy var flipCameraButton: UIButton = {
        let b = UIButton(type: .system)
        let img = UIImage(systemName: "camera.rotate.fill")
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        b.layer.cornerRadius = 22
        b.translatesAutoresizingMaskIntoConstraints = false
        b.accessibilityLabel = "Cambiar cámara"
        b.addTarget(self, action: #selector(flipCameraButtonTapped), for: .touchUpInside)
        return b
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        view.addSubview(overlayView)

        trafficLightView.translatesAutoresizingMaskIntoConstraints = false
        trafficLightView.isUserInteractionEnabled = false
        trafficLightView.setState(.noPerson)
        view.addSubview(trafficLightView)
        NSLayoutConstraint.activate([
            trafficLightView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            trafficLightView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            trafficLightView.widthAnchor.constraint(equalToConstant: 56),
            trafficLightView.heightAnchor.constraint(equalToConstant: 92)
        ])

        view.addSubview(flipCameraButton)
        NSLayoutConstraint.activate([
            flipCameraButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            flipCameraButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            flipCameraButton.widthAnchor.constraint(equalToConstant: 44),
            flipCameraButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        overlayView.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lastLoggedBadTransition = false
        checkPermissionAndConfigure()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func orientationChanged() {
        updateVideoOrientation()
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        if let scene = view.window?.windowScene {
            return scene.interfaceOrientation
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return active.interfaceOrientation
        }
        if let first = scenes.first {
            return first.interfaceOrientation
        }
        return .portrait
    }

    private func updateVideoOrientation() {
        let avOrientation = avCaptureOrientation(from: currentInterfaceOrientation())

        guard let connection = previewLayer.connection, connection.isVideoOrientationSupported else {
            syncVideoOutputOrientation(avOrientation)
            return
        }
        connection.videoOrientation = avOrientation
        syncVideoOutputOrientation(avOrientation)
    }

    private func syncVideoOutputOrientation(_ avOrientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let output = self.session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first,
               let conn = output.connection(with: .video),
               conn.isVideoOrientationSupported {
                conn.videoOrientation = avOrientation
            }
        }
    }

    private func avCaptureOrientation(from interface: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch interface {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.updateVideoOrientation()
        })
    }

    private func checkPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            let avOrient = avCaptureOrientation(from: currentInterfaceOrientation())
            sessionQueue.async { [weak self] in self?.configureSession(initialVideoOrientation: avOrient) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        let avOrient = self?.avCaptureOrientation(from: self?.currentInterfaceOrientation() ?? .portrait) ?? .portrait
                        self?.sessionQueue.async { self?.configureSession(initialVideoOrientation: avOrient) }
                    } else {
                        self?.onDismissRequest?()
                    }
                }
            }
        default:
            onDismissRequest?()
        }
    }

    private func configureSession(initialVideoOrientation: AVCaptureVideoOrientation) {
        session.beginConfiguration()
        session.sessionPreset = .high

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in self?.onDismissRequest?() }
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = initialVideoOrientation
            }
            if conn.isVideoMirroringSupported {
                conn.isVideoMirrored = (cameraPosition == .front)
            }
        }

        session.commitConfiguration()

        output.setSampleBufferDelegate(self, queue: visionQueue)

        session.startRunning()

        DispatchQueue.main.async { [weak self] in
            self?.updateVideoOrientation()
        }
    }

    @objc private func flipCameraButtonTapped() {
        let avOrient = avCaptureOrientation(from: currentInterfaceOrientation())
        sessionQueue.async { [weak self] in
            self?.performCameraSwitch(captureOrientation: avOrient)
        }
    }

    private func performCameraSwitch(captureOrientation: AVCaptureVideoOrientation) {
        guard session.outputs.contains(where: { $0 is AVCaptureVideoDataOutput }) else { return }

        let nextPosition: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: nextPosition),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            return
        }
        session.addInput(newInput)
        cameraPosition = nextPosition

        if let conn = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first?.connection(with: .video) {
            if conn.isVideoMirroringSupported {
                conn.isVideoMirrored = (nextPosition == .front)
            }
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = captureOrientation
            }
        }
        session.commitConfiguration()

        DispatchQueue.main.async { [weak self] in
            self?.poseTracker.reset()
            self?.overlayView.clear()
            self?.trafficLightView.setState(.noPerson)
            self?.bridge?.setPosture(.none)
            self?.lastLoggedBadTransition = false
            self?.updateVideoOrientation()
        }
    }
}

// MARK: - Video frames → Vision

extension PoseCameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessingFrame = false
            DispatchQueue.main.async { [weak self] in
                self?.trafficLightView.setState(.noPerson)
                self?.bridge?.setPosture(.none)
            }
            return
        }

        let orientation = visionImageOrientation(
            for: connection.videoOrientation,
            cameraPosition: cameraPosition
        )

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            try handler.perform([poseRequest])
        } catch {
            isProcessingFrame = false
            DispatchQueue.main.async { [weak self] in
                self?.trafficLightView.setState(.noPerson)
                self?.bridge?.setPosture(.none)
            }
            return
        }

        let rawObservations = (poseRequest.results ?? []).compactMap { $0 as? VNHumanBodyPoseObservation }
        let smoothedTracks = poseTracker.update(observations: rawObservations, sampleBuffer: sampleBuffer)

        let primaryIdx = primaryTrackIndex(smoothedTracks)
        let primaryJoints = smoothedTracks.indices.contains(primaryIdx) ? smoothedTracks[primaryIdx] : [:]
        let isPoorPosture = PostureAnalyzer.isHunchedOrPoorPosture(joints: primaryJoints)

        let isFront = cameraPosition == .front

        var perTrackSegments: [[(CGPoint, CGPoint)]] = []
        for track in smoothedTracks {
            var rawSegments: [(CGPoint, CGPoint)] = []
            for (a, b) in bodyJointConnections {
                guard let pa = track[a], let pb = track[b],
                      pa.confidence > 0.25,
                      pb.confidence > 0.25 else { continue }
                rawSegments.append((pa.location, pb.location))
            }
            perTrackSegments.append(rawSegments)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.visionQueue.async { self.isProcessingFrame = false }
            }

            guard let previewLayer = self.previewLayer else { return }

            if smoothedTracks.isEmpty {
                self.overlayView.clear()
                self.trafficLightView.setState(.noPerson)
                self.bridge?.setPosture(.none)
                return
            }

            if isPoorPosture {
                self.trafficLightView.setState(.badPosture)
                self.bridge?.setPosture(.bad)
                if !self.lastLoggedBadTransition {
                    self.lastLoggedBadTransition = true
                    self.bridge?.appendLog("Postura incorrecta (joroba o cabeza adelantada)")
                }
            } else {
                self.trafficLightView.setState(.goodPosture)
                self.bridge?.setPosture(.good)
                self.lastLoggedBadTransition = false
            }

            var lineSegments: [(CGPoint, CGPoint)] = []
            var jointPoints: [CGPoint] = []
            for rawSegments in perTrackSegments {
                for (la, lb) in rawSegments {
                    let p1 = self.convertVisionPoint(la, previewLayer: previewLayer, frontCamera: isFront)
                    let p2 = self.convertVisionPoint(lb, previewLayer: previewLayer, frontCamera: isFront)
                    lineSegments.append((p1, p2))
                    jointPoints.append(contentsOf: [p1, p2])
                }
            }
            if lineSegments.isEmpty {
                self.overlayView.clear()
                return
            }
            self.overlayView.update(lines: lineSegments, joints: jointPoints)
        }
    }

    private func convertVisionPoint(
        _ normalized: CGPoint,
        previewLayer: AVCaptureVideoPreviewLayer,
        frontCamera: Bool
    ) -> CGPoint {
        var nx = normalized.x
        var ny = 1.0 - normalized.y

        if frontCamera, previewLayer.connection?.isVideoMirrored == true {
            nx = 1.0 - nx
        }

        let metadataRect = CGRect(x: nx, y: ny, width: 0.02, height: 0.02)
        let layerRect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        let h = previewLayer.bounds.height
        guard h > 0 else {
            return CGPoint(x: layerRect.midX, y: layerRect.midY)
        }
        return CGPoint(x: layerRect.midX, y: h - layerRect.midY)
    }

    private func visionImageOrientation(
        for videoOrientation: AVCaptureVideoOrientation,
        cameraPosition: AVCaptureDevice.Position
    ) -> CGImagePropertyOrientation {
        switch videoOrientation {
        case .portrait:
            return cameraPosition == .front ? .leftMirrored : .right
        case .portraitUpsideDown:
            return cameraPosition == .front ? .rightMirrored : .left
        case .landscapeLeft:
            return cameraPosition == .front ? .downMirrored : .up
        case .landscapeRight:
            return cameraPosition == .front ? .upMirrored : .down
        @unknown default:
            return cameraPosition == .front ? .leftMirrored : .right
        }
    }
}

// MARK: - Semáforo (rojo / verde / naranja)

private enum TrafficLightState {
    case noPerson
    case goodPosture
    case badPosture
}

private final class TrafficLightIndicatorView: UIView {
    private let housing = UIView()
    private let lampView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits.insert(.updatesFrequently)
        accessibilityLabel = "Estado de postura"

        housing.translatesAutoresizingMaskIntoConstraints = false
        housing.backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        housing.layer.cornerRadius = 14
        housing.layer.borderWidth = 1.5
        housing.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor

        lampView.translatesAutoresizingMaskIntoConstraints = false
        lampView.layer.cornerRadius = 20
        lampView.backgroundColor = .systemRed
        lampView.layer.shadowOpacity = 0.85
        lampView.layer.shadowRadius = 10
        lampView.layer.shadowOffset = .zero
        lampView.layer.masksToBounds = false

        addSubview(housing)
        housing.addSubview(lampView)

        NSLayoutConstraint.activate([
            housing.topAnchor.constraint(equalTo: topAnchor),
            housing.leadingAnchor.constraint(equalTo: leadingAnchor),
            housing.trailingAnchor.constraint(equalTo: trailingAnchor),
            housing.bottomAnchor.constraint(equalTo: bottomAnchor),

            lampView.centerXAnchor.constraint(equalTo: housing.centerXAnchor),
            lampView.centerYAnchor.constraint(equalTo: housing.centerYAnchor),
            lampView.widthAnchor.constraint(equalToConstant: 40),
            lampView.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setState(_ state: TrafficLightState) {
        let color: UIColor
        let value: String
        switch state {
        case .noPerson:
            color = .systemRed
            value = "Sin persona"
        case .goodPosture:
            color = .systemGreen
            value = "Postura correcta"
        case .badPosture:
            color = .systemOrange
            value = "Postura incorrecta"
        }
        accessibilityValue = value

        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.lampView.backgroundColor = color
            self.lampView.layer.shadowColor = color.cgColor
        }
    }
}

// MARK: - Capa de dibujo del esqueleto

private final class PoseOverlayView: UIView {
    private var lineSegments: [(CGPoint, CGPoint)] = []
    private var joints: [CGPoint] = []

    func update(lines: [(CGPoint, CGPoint)], joints: [CGPoint]) {
        self.lineSegments = lines
        self.joints = joints
        setNeedsDisplay()
    }

    func clear() {
        lineSegments = []
        joints = []
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setLineWidth(4)
        ctx.setStrokeColor(UIColor(red: 0.4, green: 1.0, blue: 0.55, alpha: 0.95).cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for (p1, p2) in lineSegments {
            ctx.move(to: p1)
            ctx.addLine(to: p2)
            ctx.strokePath()
        }

        let r: CGFloat = 6
        ctx.setFillColor(UIColor(red: 0.9, green: 1.0, blue: 0.95, alpha: 0.9).cgColor)
        for p in joints {
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }
}
