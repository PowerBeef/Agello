import AVFoundation
import SwiftUI
import UIKit

/// Where the attach menu's Camera and Scan document come from: on iPhone, the camera and
/// VisionKit's document camera, full screen.
@MainActor
enum CaptureSources {
  static var cameraAvailable: Bool { CameraPicker.isAvailable }
  static var scannerAvailable: Bool { DocumentScanner.isAvailable }
}

extension View {
  /// Shows the camera while `camera` is set and the document scanner while `scanner` is.
  func captureSources(
    camera: Binding<Bool>, scanner: Binding<Bool>, onPhoto: @escaping (Data) -> Void,
    onScan: @escaping ([Data]) -> Void
  ) -> some View {
    modifier(
      CaptureSourcesModifier(
        camera: camera, scanner: scanner, onPhoto: onPhoto, onScan: onScan))
  }
}

private struct CaptureSourcesModifier: ViewModifier {
  private enum ActiveCapture: Identifiable {
    case camera, scanner
    var id: Self { self }
  }

  @Environment(AppState.self) private var appState: AppState?
  @Environment(ShellModel.self) private var shell: ShellModel?

  @Binding var camera: Bool
  @Binding var scanner: Bool
  let onPhoto: (Data) -> Void
  let onScan: ([Data]) -> Void

  @State private var activeCapture: ActiveCapture?
  @State private var showCameraDeniedAlert = false
  @State private var permissionTask: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .onChange(of: camera, initial: true) { _, requested in
        if requested {
          requestCameraAccessAndPresent()
        } else {
          permissionTask?.cancel()
          permissionTask = nil
          if activeCapture == .camera { activeCapture = nil }
        }
      }
      .onChange(of: scanner, initial: true) { _, requested in
        if requested {
          presentScannerIfAuthorized()
        } else if activeCapture == .scanner {
          activeCapture = nil
        }
      }
      .onChange(of: shell?.dismissCoversToken) { old, new in
        guard old != nil, old != new else { return }
        permissionTask?.cancel()
        permissionTask = nil
        camera = false
        scanner = false
        activeCapture = nil
      }
      .onDisappear {
        permissionTask?.cancel()
        permissionTask = nil
      }
      .fullScreenCover(
        item: $activeCapture,
        onDismiss: {
          camera = false
          scanner = false
          shell?.isPresentingCaptureCover = false
          shell?.handleModalDismissed()
        }
      ) { mode in
        switch mode {
        case .camera:
          CameraPicker(onCapture: onPhoto)
            .ignoresSafeArea()
        case .scanner:
          DocumentScanner(onScan: onScan) { error in
            appState?.generationError = error.localizedDescription
          }
          .ignoresSafeArea()
        }
      }
      .alert("Camera access denied", isPresented: $showCameraDeniedAlert) {
        Button("Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Enable camera access in Settings to take photos or scan documents.")
      }
  }

  private func requestCameraAccessAndPresent() {
    guard CameraPicker.isAvailable else {
      camera = false
      appState?.notice = String(localized: "Camera isn't available on this device.")
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      scanner = false
      shell?.isPresentingCaptureCover = true
      activeCapture = .camera
    case .notDetermined:
      permissionTask?.cancel()
      permissionTask = Task {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard !Task.isCancelled, camera else { return }
        if granted {
          scanner = false
          shell?.isPresentingCaptureCover = true
          activeCapture = .camera
        } else {
          camera = false
          showCameraDeniedAlert = true
        }
      }
    case .denied, .restricted:
      camera = false
      showCameraDeniedAlert = true
    @unknown default:
      camera = false
      showCameraDeniedAlert = true
    }
  }

  private func presentScannerIfAuthorized() {
    guard DocumentScanner.isAvailable else {
      scanner = false
      appState?.notice = String(localized: "Document scanner isn't available on this device.")
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      camera = false
      shell?.isPresentingCaptureCover = true
      activeCapture = .scanner
    case .notDetermined:
      permissionTask?.cancel()
      permissionTask = Task {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard !Task.isCancelled, scanner else { return }
        if granted {
          camera = false
          shell?.isPresentingCaptureCover = true
          activeCapture = .scanner
        } else {
          scanner = false
          showCameraDeniedAlert = true
        }
      }
    case .denied, .restricted:
      scanner = false
      showCameraDeniedAlert = true
    @unknown default:
      scanner = false
      showCameraDeniedAlert = true
    }
  }
}
