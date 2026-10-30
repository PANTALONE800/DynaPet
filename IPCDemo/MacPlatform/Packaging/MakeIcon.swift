import Foundation
import AppKit
import ImageIO

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let first = sheet.cropping(to: CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot read existing icon asset") }
context.interpolationQuality = .high
context.draw(first, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else { fatalError("Cannot write icon") }
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
