# ComputoUbicuo
The silent coach project - Computo Ubicuo

## 1. Implementación técnica: Multiple Object Tracking (MOT)

Siguiendo la retroalimentación técnica, implementamos el **filtro de Kalman**.

**Propósito:** Lograr un rastreo de múltiples objetivos (Multiple Object Tracking, MOT) de forma estable.

**Beneficio:** El filtro de Kalman nos permite predecir la posición de las articulaciones incluso si hay una oclusión temporal (por ejemplo, si un trabajador se cruza frente a otro), evitando que el modelo KNN pierda el rastro de la postura.
