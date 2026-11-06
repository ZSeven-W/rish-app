#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tempfile'

root = File.expand_path('..', __dir__)
source = File.join(root, 'brand', 'dsh-app-icon-1024.png')
abort "missing icon master: #{source}" unless File.file?(source)

platform_flag = ARGV.first
valid_flags = [nil, '--android-only', '--ios-only']
abort "usage: #{File.basename($PROGRAM_NAME)} [--android-only|--ios-only]" unless valid_flags.include?(platform_flag)
generate_ios = platform_flag != '--android-only'
generate_android = platform_flag != '--ios-only'

ios_root = File.join(
  root,
  'apps/gpui/ios/Resources/Images.xcassets/AppIcon.appiconset',
)
android_root = File.join(root, 'apps/gpui/android/app/src/main/res')

def resize(source, output, size)
  FileUtils.mkdir_p(File.dirname(output))
  text, status = Open3.capture2e(
    'sips', '-z', size.to_s, size.to_s, source, '--out', output,
  )
  abort "icon resize failed for #{output}: #{text}" unless status.success?
end

def render_circular_icons(source, outputs)
  outputs.each_key { |output| FileUtils.mkdir_p(File.dirname(output)) }

  swift_source = <<~'SWIFT'
    import AppKit
    import Foundation

    let arguments = CommandLine.arguments
    guard arguments.count >= 4, arguments.count.isMultiple(of: 2) else {
      fatalError("expected: source output size [output size ...]")
    }

    let sourcePath = arguments[1]
    guard let source = NSImage(contentsOfFile: sourcePath) else {
      fatalError("could not read source icon at \(sourcePath)")
    }

    for index in stride(from: 2, to: arguments.count, by: 2) {
      let outputPath = arguments[index]
      guard let size = Int(arguments[index + 1]), size > 0 else {
        fatalError("invalid icon size: \(arguments[index + 1])")
      }

      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32
      ) else {
        fatalError("could not allocate \(size)x\(size) icon")
      }

      bitmap.size = NSSize(width: size, height: size)
      guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("could not create icon graphics context")
      }

      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphicsContext
      graphicsContext.imageInterpolation = .high

      let bounds = NSRect(x: 0, y: 0, width: size, height: size)
      NSColor.clear.setFill()
      bounds.fill()
      NSBezierPath(ovalIn: bounds).addClip()
      source.draw(
        in: bounds,
        from: NSRect(origin: .zero, size: source.size),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
      graphicsContext.flushGraphics()
      NSGraphicsContext.restoreGraphicsState()

      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("could not encode round icon")
      }
      try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
  SWIFT

  Tempfile.create(['dsh-round-icon', '.swift']) do |helper|
    helper.write(swift_source)
    helper.flush
    arguments = outputs.flat_map { |output, size| [output, size.to_s] }
    text, status = Open3.capture2e(
      'xcrun', 'swift', helper.path, source, *arguments,
    )
    abort "round icon rendering failed: #{text}" unless status.success?
  end
end

def render_adaptive_art(source, color_output, monochrome_output, size)
  [color_output, monochrome_output].each do |output|
    FileUtils.mkdir_p(File.dirname(output))
  end

  swift_source = <<~'SWIFT'
    import AppKit
    import Foundation

    let arguments = CommandLine.arguments
    guard arguments.count == 5, let size = Int(arguments[4]), size > 0 else {
      fatalError("expected: source color-output monochrome-output size")
    }

    let sourcePath = arguments[1]
    guard let source = NSImage(contentsOfFile: sourcePath) else {
      fatalError("could not read source icon at \(sourcePath)")
    }

    func render(outputPath: String, monochrome: Bool) throws {
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32
      ) else {
        fatalError("could not allocate adaptive icon art")
      }

      bitmap.size = NSSize(width: size, height: size)
      guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("could not create adaptive icon graphics context")
      }

      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphicsContext
      graphicsContext.imageInterpolation = .high
      let bounds = NSRect(x: 0, y: 0, width: size, height: size)
      source.draw(
        in: bounds,
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
      graphicsContext.flushGraphics()
      NSGraphicsContext.restoreGraphicsState()

      guard let pixels = bitmap.bitmapData else {
        fatalError("could not access adaptive icon pixels")
      }

      // Extract the bright ivory/coral mark from its near-black master. This
      // creates a real transparent foreground layer without redrawing or
      // approximating the approved artwork.
      let backgroundLuma = 18.0
      let solidLuma = 170.0
      let backgroundChannel = 5.0
      for y in 0..<size {
        for x in 0..<size {
          let offset = y * bitmap.bytesPerRow + x * 4
          let red = Double(pixels[offset])
          let green = Double(pixels[offset + 1])
          let blue = Double(pixels[offset + 2])
          let luma = max(red, max(green, blue))
          let matte = min(1.0, max(0.0, (luma - backgroundLuma) / (solidLuma - backgroundLuma)))
          let alpha = UInt8((matte * 255.0).rounded())

          if monochrome {
            pixels[offset] = alpha
            pixels[offset + 1] = alpha
            pixels[offset + 2] = alpha
          } else if alpha == 0 {
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
          } else {
            let maximum = Double(alpha)
            pixels[offset] = UInt8(min(maximum, max(0.0, red - backgroundChannel * (1.0 - matte))).rounded())
            pixels[offset + 1] = UInt8(min(maximum, max(0.0, green - backgroundChannel * (1.0 - matte))).rounded())
            pixels[offset + 2] = UInt8(min(maximum, max(0.0, blue - backgroundChannel * (1.0 - matte))).rounded())
          }
          pixels[offset + 3] = alpha
        }
      }

      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("could not encode adaptive icon art")
      }
      try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    try render(outputPath: arguments[2], monochrome: false)
    try render(outputPath: arguments[3], monochrome: true)
  SWIFT

  Tempfile.create(['dsh-adaptive-icon', '.swift']) do |helper|
    helper.write(swift_source)
    helper.flush
    text, status = Open3.capture2e(
      'xcrun', 'swift', helper.path, source, color_output,
      monochrome_output, size.to_s,
    )
    abort "adaptive icon rendering failed: #{text}" unless status.success?
  end
end

if generate_ios
  {
    'Icon-20@2x.png' => 40,
    'Icon-20@3x.png' => 60,
    'Icon-29@2x.png' => 58,
    'Icon-29@3x.png' => 87,
    'Icon-40@2x.png' => 80,
    'Icon-40@3x.png' => 120,
    'Icon-60@2x.png' => 120,
    'Icon-60@3x.png' => 180,
    'Icon-iPad-20.png' => 20,
    'Icon-iPad-20@2x.png' => 40,
    'Icon-iPad-29.png' => 29,
    'Icon-iPad-29@2x.png' => 58,
    'Icon-iPad-40.png' => 40,
    'Icon-iPad-40@2x.png' => 80,
    'Icon-iPad-76.png' => 76,
    'Icon-iPad-76@2x.png' => 152,
    'Icon-iPad-83.5@2x.png' => 167,
    'Icon-1024.png' => 1024,
  }.each do |name, size|
    resize(source, File.join(ios_root, name), size)
  end
end

android_sizes = {
  'mipmap-mdpi' => 48,
  'mipmap-hdpi' => 72,
  'mipmap-xhdpi' => 96,
  'mipmap-xxhdpi' => 144,
  'mipmap-xxxhdpi' => 192,
}

if generate_android
  android_sizes.each do |folder, size|
    resize(source, File.join(android_root, folder, 'ic_launcher.png'), size)
  end

  render_circular_icons(
    source,
    android_sizes.to_h do |folder, size|
      [File.join(android_root, folder, 'ic_launcher_round.png'), size]
    end,
  )

  # Android adaptive icons use transparent color and monochrome foreground
  # layers. XML applies a small optical inset to keep the mark within every
  # launcher mask's safe zone.
  render_adaptive_art(
    source,
    File.join(android_root, 'drawable-nodpi', 'ic_launcher_foreground_art.png'),
    File.join(android_root, 'drawable-nodpi', 'ic_launcher_monochrome_art.png'),
    432,
  )
end

generated = []
generated << 'iOS' if generate_ios
generated << 'Android legacy/round/adaptive' if generate_android
puts "generated #{generated.join(' and ')} icon artwork"
