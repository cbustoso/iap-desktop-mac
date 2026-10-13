# FreeRDP embedding spike

Spike aislado; no es dependencia del producto ni modifica el `Package.swift` raíz.
Comprueba con Swift 6/macOS 14 que un target C puede exponer un framebuffer BGRX32 a
una `NSView` AppKit programática. Además detecta en compilación si existen los headers
`freerdp/freerdp.h` y `freerdp/gdi/gdi.h`.

```sh
cd Spikes/FreeRDPEmbedding
swift build
swift run FreeRDPEmbeddingSpike
```

Que este paquete compile **no prueba** el enlace con FreeRDP: no se vendoriza una copia
del proyecto ni se falsean sus símbolos. Si los headers no están presentes, el binario
lo informa. La evaluación del artefacto upstream, dependencias y firma está en
`specs/rdp/transport-decision-freerdp.md`.
