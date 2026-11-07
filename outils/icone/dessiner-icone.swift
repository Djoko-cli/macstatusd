// Dessine la maîtresse de l'icône de macstatusd (CoreGraphics, aucun fichier d'entrée).
//
// Usage : swift outils/icone/dessiner-icone.swift <variante a|b|c> <taille> <sortie.png> [--canevas <facteur>]
//
//   variante  a : écran crème sur fond clair, point d'état rouge-orangé
//             b : symbole d'alimentation crème sur fond orange
//             c : écran lumineux et point ambré sur fond sarcelle profond
//   taille    côté du PNG en pixels (1024 pour la maîtresse, 32 et 16 pour les essais de lisibilité)
//   --canevas facteur > 1 : la maîtresse est centrée sur un canevas plus grand (gris moyen, cadre
//             de 1024 en pointillé) pour vérifier qu'aucune forme n'est coupée.
//
// Cadre commun, relevé sur les autres apps : tuile arrondie de 824 px dans 1024 (80 %,
// marge de 100), ombre douce portée vers le bas, glyphe de 45 à 55 % de la tuile, aplats.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let espace = CGColorSpace(name: CGColorSpace.sRGB)!

func couleur(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: espace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

// Tuile arrondie (rayon relevé sur les autres apps : environ 23 % du côté).
func carreContinu(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: 188, cornerHeight: 188, transform: nil)
}

func degrade(_ ctx: CGContext, de: CGColor, vers: CGColor, depuis: CGPoint, jusque: CGPoint) {
    let g = CGGradient(colorsSpace: espace, colors: [de, vers] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: depuis, end: jusque, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let tuile = CGRect(x: 100, y: 100, width: 824, height: 824)

// Tuile : ombre, puis remplissage fourni par l'appelant (la tuile est le clip courant).
func dessinerTuile(_ ctx: CGContext, remplissage: (CGContext) -> Void) {
    let forme = carreContinu(tuile)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: couleur(0x000000, 0.28))
    ctx.addPath(forme)
    ctx.setFillColor(couleur(0x808080))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(forme)
    ctx.clip()
    remplissage(ctx)
    ctx.restoreGState()
    // Filet intérieur discret.
    ctx.saveGState()
    ctx.addPath(forme)
    ctx.setStrokeColor(couleur(0xFFFFFF, 0.14))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

func rectArrondi(_ ctx: CGContext, _ r: CGRect, _ rayon: CGFloat) {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: rayon, cornerHeight: rayon, transform: nil))
}

// Variante a : écran crème, point d'état rouge-orangé, pied en barre.
func varianteA(_ ctx: CGContext) {
    dessinerTuile(ctx) { c in
        c.setFillColor(couleur(0xEDE6DA)); c.fill(tuile)
    }
    let rouge = couleur(0xD4412A)
    ctx.setStrokeColor(rouge)
    ctx.setLineWidth(40)
    rectArrondi(ctx, CGRect(x: 292, y: 400, width: 440, height: 310), 46)
    ctx.strokePath()
    ctx.setFillColor(rouge)
    ctx.fillEllipse(in: CGRect(x: 512 - 62, y: 555 - 62, width: 124, height: 124))
    ctx.fill(CGRect(x: 482, y: 340, width: 60, height: 40))        // col
    ctx.fill(CGRect(x: 372, y: 300, width: 280, height: 40))       // pied
}

// Variante b : symbole d'alimentation crème sur fond orange.
func varianteB(_ ctx: CGContext) {
    dessinerTuile(ctx) { c in
        degrade(c, de: couleur(0xE24400), vers: couleur(0xF98419), depuis: CGPoint(x: 100, y: 100), jusque: CGPoint(x: 924, y: 924))
    }
    let creme = couleur(0xF8EEE3)
    ctx.setStrokeColor(creme)
    ctx.setLineCap(.round)
    ctx.setLineWidth(60)
    ctx.addArc(center: CGPoint(x: 512, y: 500), radius: 205, startAngle: 128 * .pi / 180, endAngle: 52 * .pi / 180, clockwise: false)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 512, y: 520))
    ctx.addLine(to: CGPoint(x: 512, y: 730))
    ctx.strokePath()
}

// Variante c : écran lumineux, point ambré, fond sarcelle profond.
func varianteC(_ ctx: CGContext) {
    dessinerTuile(ctx) { c in
        let g = CGGradient(colorsSpace: espace, colors: [couleur(0x1B8F86), couleur(0x0A2E33)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: 360, y: 700), startRadius: 0,
                             endCenter: CGPoint(x: 512, y: 512), endRadius: 640, options: [.drawsAfterEndLocation])
    }
    let centre = CGPoint(x: 512, y: 560)
    // Écran : plaque claire, fenêtre sombre, point ambré lumineux, pied.
    let plaque = CGRect(x: 322, y: 420, width: 380, height: 280)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: couleur(0x5CE6D4, 0.55))
    rectArrondi(ctx, plaque, 40)
    ctx.setFillColor(couleur(0xE9F8F5))
    ctx.fillPath()
    ctx.restoreGState()
    rectArrondi(ctx, plaque.insetBy(dx: 26, dy: 26), 22)
    ctx.setFillColor(couleur(0x0E3B40))
    ctx.fillPath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: couleur(0xFFD04A, 0.9))
    ctx.setFillColor(couleur(0xFFD04A))
    ctx.fillEllipse(in: CGRect(x: centre.x - 56, y: centre.y - 56, width: 112, height: 112))
    ctx.restoreGState()
    ctx.setFillColor(couleur(0xE9F8F5))
    ctx.fill(CGRect(x: 484, y: 362, width: 56, height: 58))
    rectArrondi(ctx, CGRect(x: 392, y: 330, width: 240, height: 36), 18)
    ctx.fillPath()
}

// --- Programme -------------------------------------------------------------------
let args = CommandLine.arguments
guard args.count >= 4, let taille = Int(args[2]), taille > 0 else {
    FileHandle.standardError.write(Data("Usage : swift dessiner-icone.swift <a|b|c> <taille> <sortie.png> [--canevas <facteur>]\n".utf8))
    exit(2)
}
var facteur = 1.0
if args.count >= 6, args[4] == "--canevas", let f = Double(args[5]), f >= 1 { facteur = f }
let variantes: [String: (CGContext) -> Void] = ["a": varianteA, "b": varianteB, "c": varianteC]
guard let dessin = variantes[args[1]] else {
    FileHandle.standardError.write(Data("variante inconnue : \(args[1])\n".utf8))
    exit(2)
}

let cote = Int((Double(taille) * facteur).rounded())
guard let ctx = CGContext(data: nil, width: cote, height: cote, bitsPerComponent: 8, bytesPerRow: 0, space: espace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)
if facteur > 1 {
    ctx.setFillColor(couleur(0x8A8A8A)); ctx.fill(CGRect(x: 0, y: 0, width: cote, height: cote))
}
// Espace de dessin : 1024 unités centrées dans le canevas.
let echelle = Double(taille) / 1024
ctx.translateBy(x: CGFloat(Double(cote - taille) / 2), y: CGFloat(Double(cote - taille) / 2))
ctx.scaleBy(x: CGFloat(echelle), y: CGFloat(echelle))
dessin(ctx)
if facteur > 1 {
    ctx.setStrokeColor(couleur(0xFFFFFF, 0.9)); ctx.setLineWidth(3 / CGFloat(echelle))
    ctx.setLineDash(phase: 0, lengths: [14 / CGFloat(echelle), 10 / CGFloat(echelle)])
    ctx.stroke(CGRect(x: 0, y: 0, width: 1024, height: 1024))
}

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
