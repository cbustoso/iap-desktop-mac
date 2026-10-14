#!/usr/bin/env swift
// GH-79: icono de IAP Desktop Mac, dibujado 100% por código (CoreGraphics +
// ImageIO, sin assets externos descargados). Motivo: nube (IAP = túnel hacia
// Google Cloud) + terminal con candado (acceso remoto seguro vía SSH/RDP
// detrás de Identity-Aware Proxy), fondo degradado azul estilo macOS
// (squircle a pantalla completa, como un icono nativo de Big Sur+).
//
// Uso: swift tools/generate-app-icon.swift <directorio-salida-iconset>
// Genera los 10 PNG del iconset estándar de macOS (16/32/128/256/512 + @2x).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paleta

private let gradientTop = CGColor(red: 0.33, green: 0.63, blue: 0.98, alpha: 1)
private let gradientBottom = CGColor(red: 0.04, green: 0.16, blue: 0.46, alpha: 1)
private let cloudWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 0.96)
private let terminalDark = CGColor(red: 0.05, green: 0.09, blue: 0.17, alpha: 0.97)
private let terminalBorder = CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)
private let promptGreen = CGColor(red: 0.29, green: 0.95, blue: 0.42, alpha: 1)
private let lockColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
private let trafficRed = CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1)
private let trafficYellow = CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1)
private let trafficGreen = CGColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)

// MARK: - Helpers

private func roundedRectPath(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}

private func circlePath(center: CGPoint, radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
}

/// Dibuja el icono completo a tamaño `size` (pixeles cuadrados) en un
/// contexto bitmap nuevo y lo devuelve.
private func drawIcon(size: Int) -> CGContext {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("No se pudo crear el contexto bitmap de \(size)px")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)

    // 1) Fondo: squircle a pantalla completa (aproximación macOS Big Sur+,
    //    radio ~22% del lado) con degradado diagonal azul claro → azul noche.
    let backgroundRect = CGRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.2237
    let background = roundedRectPath(backgroundRect, cornerRadius: cornerRadius)
    ctx.saveGState()
    ctx.addPath(background)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace, colors: [gradientTop, gradientBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // 1b) Brillo superior sutil (look "glossy" nativo, sin blur: un óvalo
    //     translúcido ancho en la mitad superior).
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    let glossPath = CGPath(
        ellipseIn: CGRect(x: s * 0.05, y: s * 0.56, width: s * 0.90, height: s * 0.46), transform: nil)
    ctx.addPath(glossPath)
    ctx.fillPath()
    ctx.restoreGState()

    // 2) Nube: pastilla base + 3 círculos solapados (silueta clásica),
    //    centrada en el tercio superior.
    let cloudCenterY = s * 0.635
    let cloudPath = CGMutablePath()
    cloudPath.addPath(roundedRectPath(
        CGRect(x: s * 0.19, y: cloudCenterY - s * 0.085, width: s * 0.62, height: s * 0.12),
        cornerRadius: s * 0.06))
    cloudPath.addPath(circlePath(center: CGPoint(x: s * 0.305, y: cloudCenterY + s * 0.015), radius: s * 0.095))
    cloudPath.addPath(circlePath(center: CGPoint(x: s * 0.475, y: cloudCenterY + s * 0.075), radius: s * 0.135))
    cloudPath.addPath(circlePath(center: CGPoint(x: s * 0.645, y: cloudCenterY + s * 0.01), radius: s * 0.10))
    ctx.setFillColor(cloudWhite)
    ctx.addPath(cloudPath)
    ctx.fillPath()

    // 3) Terminal: ventana oscura redondeada, solapando el borde inferior
    //    de la nube, con "semáforo" macOS + prompt ">_" + candado.
    let terminalRect = CGRect(x: s * 0.195, y: s * 0.145, width: s * 0.61, height: s * 0.325)
    let terminalRadius = s * 0.045
    let terminalPath = roundedRectPath(terminalRect, cornerRadius: terminalRadius)
    ctx.setFillColor(terminalDark)
    ctx.addPath(terminalPath)
    ctx.fillPath()
    ctx.setStrokeColor(terminalBorder)
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.addPath(terminalPath)
    ctx.strokePath()

    // 3a) Semáforo (tres puntos, estilo barra de título de Terminal.app).
    let dotRadius = s * 0.013
    let dotY = terminalRect.maxY - s * 0.038
    let dotStartX = terminalRect.minX + s * 0.045
    let dotSpacing = s * 0.032
    for (index, color) in [trafficRed, trafficYellow, trafficGreen].enumerated() {
        ctx.setFillColor(color)
        ctx.addPath(circlePath(center: CGPoint(x: dotStartX + CGFloat(index) * dotSpacing, y: dotY), radius: dotRadius))
        ctx.fillPath()
    }

    // 3b) Prompt ">_" (vectorial, sin fuentes): chevron + cursor.
    let promptLineWidth = max(1.5, s * 0.018)
    ctx.setStrokeColor(promptGreen)
    ctx.setLineWidth(promptLineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let chevronTopY = terminalRect.minY + s * 0.145
    let chevronMidY = terminalRect.minY + s * 0.105
    let chevronBottomY = terminalRect.minY + s * 0.065
    let chevronX0 = terminalRect.minX + s * 0.05
    let chevronX1 = chevronX0 + s * 0.045
    ctx.beginPath()
    ctx.move(to: CGPoint(x: chevronX0, y: chevronTopY))
    ctx.addLine(to: CGPoint(x: chevronX1, y: chevronMidY))
    ctx.addLine(to: CGPoint(x: chevronX0, y: chevronBottomY))
    ctx.strokePath()
    ctx.setFillColor(promptGreen)
    let cursorRect = CGRect(
        x: chevronX1 + s * 0.012, y: chevronBottomY, width: s * 0.055, height: promptLineWidth)
    ctx.fill(cursorRect)

    // 3c) Candado: cuerpo redondeado + grillete en arco (acceso seguro).
    let lockBodyWidth = s * 0.115
    let lockBodyHeight = s * 0.095
    let lockCenterX = terminalRect.maxX - s * 0.115
    let lockBodyRect = CGRect(
        x: lockCenterX - lockBodyWidth / 2, y: terminalRect.minY + s * 0.065,
        width: lockBodyWidth, height: lockBodyHeight)
    ctx.setFillColor(lockColor)
    ctx.addPath(roundedRectPath(lockBodyRect, cornerRadius: s * 0.018))
    ctx.fillPath()
    // Ojo de la cerradura (recorte simple: círculo + rectángulo oscuros).
    ctx.setFillColor(terminalDark)
    let keyholeRadius = s * 0.012
    let keyholeCenter = CGPoint(x: lockCenterX, y: lockBodyRect.midY + s * 0.01)
    ctx.addPath(circlePath(center: keyholeCenter, radius: keyholeRadius))
    ctx.fillPath()
    ctx.fill(CGRect(x: keyholeCenter.x - keyholeRadius * 0.5, y: lockBodyRect.minY + s * 0.012,
                     width: keyholeRadius, height: keyholeCenter.y - lockBodyRect.minY - s * 0.01))
    // Grillete (arco abierto por arriba del cuerpo).
    ctx.setStrokeColor(lockColor)
    ctx.setLineWidth(max(1.5, s * 0.02))
    ctx.setLineCap(.round)
    let shackleRadius = lockBodyWidth * 0.38
    let shackleCenter = CGPoint(x: lockCenterX, y: lockBodyRect.maxY)
    ctx.beginPath()
    ctx.addArc(
        center: shackleCenter, radius: shackleRadius,
        startAngle: CGFloat.pi, endAngle: 0, clockwise: true)
    ctx.strokePath()

    return ctx
}

private func savePNG(_ context: CGContext, to url: URL) {
    guard let image = context.makeImage() else {
        fatalError("No se pudo generar CGImage para \(url.lastPathComponent)")
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("No se pudo crear el destino PNG para \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("No se pudo finalizar el PNG \(url.lastPathComponent)")
    }
}

// MARK: - Entrada: tamaños estándar del iconset de macOS

struct IconSpec {
    let fileName: String
    let pixels: Int
}

let specs: [IconSpec] = [
    IconSpec(fileName: "icon_16x16.png", pixels: 16),
    IconSpec(fileName: "icon_16x16@2x.png", pixels: 32),
    IconSpec(fileName: "icon_32x32.png", pixels: 32),
    IconSpec(fileName: "icon_32x32@2x.png", pixels: 64),
    IconSpec(fileName: "icon_128x128.png", pixels: 128),
    IconSpec(fileName: "icon_128x128@2x.png", pixels: 256),
    IconSpec(fileName: "icon_256x256.png", pixels: 256),
    IconSpec(fileName: "icon_256x256@2x.png", pixels: 512),
    IconSpec(fileName: "icon_512x512.png", pixels: 512),
    IconSpec(fileName: "icon_512x512@2x.png", pixels: 1024),
]

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("Uso: swift generate-app-icon.swift <directorio-salida-iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for spec in specs {
    let context = drawIcon(size: spec.pixels)
    savePNG(context, to: outputDirectory.appendingPathComponent(spec.fileName))
    print("OK: \(spec.fileName) (\(spec.pixels)x\(spec.pixels))")
}
