import SwiftUI
import AVFoundation
import CoreImage
import UIKit

/// Member A — CF1. The camera half of photo meal logging.
///
/// Live capture only. There is deliberately no "choose from library" path: the
/// feature being built is *photograph your meal*, and a file picker is a
/// different interaction that quietly changes what the feature is.
///
/// This owns the capture and nothing else. The on-device classifier is phase 2,
/// so the photo is real and the estimate that follows it is still scripted, and
/// the screen after this one says so. A real photo followed by invented numbers
/// presented as a measurement is the exact failure the app exists to avoid.
///
/// It also owns barcode scanning, as a second mode of the same screen rather
/// than a screen of its own. That is deliberate: a barcode is the one path in
/// this app that ends in a *measured* figure — the manufacturer's declared
/// numbers, read out of a published row (CF1) — while a photograph can only
/// ever end in an estimate. Putting the trustworthy path one tap from the
/// untrustworthy one is how the difference between them stays visible.

// MARK: - Session

@Observable
final class MealCameraModel: NSObject {
    enum Status: Equatable {
        case preparing
        case ready
        /// The user said no. Only Settings can undo it, so we say that.
        case denied
        /// Nothing to talk to — a simulator, or hardware without a rear camera.
        case unavailable(String)
    }

    private(set) var status: Status = .preparing
    private(set) var isCapturing = false

    /// True while the metadata output is actually looking for a symbol. Photo
    /// mode leaves it off, so the session does no detection work it was not
    /// asked for.
    private(set) var isScanning = false
    /// Set exactly once per scanning session, when a read has settled. The view
    /// watches this instead of being handed a closure, which keeps the
    /// acceptance rule in one place and observable from outside.
    private(set) var acceptedCode: String?
    /// The camera exists but reports none of the symbologies we asked for. Rare,
    /// and worth saying out loud rather than showing a guide that will never fire.
    private(set) var scanUnsupported = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    /// The barcode half. One output on the *existing* session — a second session
    /// would fight the first one for the camera and there is nothing it could do
    /// that this cannot.
    private let metadataOutput = AVCaptureMetadataOutput()
    /// Session configuration and `startRunning()` both block; neither may run on
    /// the main thread. Every `@Observable` mutation hops back to main.
    private let queue = DispatchQueue(label: "au.edu.sydney.elec5620.kairo.camera")
    private var pending: ((UIImage?) -> Void)?
    private var configured = false

    /// The symbologies actually printed on food packaging: EAN-13 on nearly
    /// everything sold in Australia, EAN-8 on packs too small for thirteen
    /// digits, UPC-E on North American imports, and Code 128 on the labels a
    /// supermarket prints for itself.
    ///
    /// Asking an output for a type it does not support throws, so this list is
    /// always intersected with `availableMetadataObjectTypes` before it is set.
    static let wantedSymbologies: [AVMetadataObject.ObjectType] =
        [.ean13, .ean8, .upce, .code128]

    // Debounce state. Touched only on `queue`, which is also the delegate's
    // queue, so a serial queue is the whole of the synchronisation — and it is
    // kept out of observation, because a property the main thread might be
    // observing is a property that cannot safely be written from a capture
    // callback. Nothing here is UI state; `isScanning` and `acceptedCode` are.
    @ObservationIgnored private var streakCode: String?
    @ObservationIgnored private var streakCount = 0
    @ObservationIgnored private var streakBegan: TimeInterval = 0
    @ObservationIgnored private var streakSeen: TimeInterval = 0
    @ObservationIgnored private var hasAccepted = false

    /// A read is accepted after this many consecutive frames carry the same
    /// payload *and* this much time has been spent on it. `didOutput` fires once
    /// per frame for as long as the symbol is in view — dozens of times a second
    /// on one barcode — so a single callback is a sighting, not a decision, and
    /// the first frame of a half-focused symbol is exactly the one to distrust.
    private static let requiredFrames = 3
    private static let settleSeconds: TimeInterval = 0.25
    /// A gap longer than this means the symbol left the frame, so the run starts
    /// over rather than accumulating across two separate looks at the shelf.
    private static let streakGapSeconds: TimeInterval = 0.6

    func prepare() {
        // Establish that there is a camera *before* asking to use one. Prompting
        // for access on hardware that has none spends the single permission ask
        // we get on a dialog whose answer cannot help.
        guard AVCaptureDevice.default(.builtInWideAngleCamera,
                                      for: .video, position: .back) != nil else {
            status = .unavailable("There is no camera on this device.")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            // The prompt uses NSCameraUsageDescription from apps/project.yml.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configure() } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    private func configure() {
        guard !configured else {
            resume()
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async {
                    self.status = .unavailable("There is no camera on this device.")
                }
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if self.session.canAddInput(input) { self.session.addInput(input) }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            if self.session.canAddOutput(self.metadataOutput) {
                self.session.addOutput(self.metadataOutput)
                // Callbacks land on the same serial queue the session is
                // configured on, which is where the debounce state lives.
                self.metadataOutput.setMetadataObjectsDelegate(self, queue: self.queue)
            }
            self.session.commitConfiguration()
            // `metadataObjectTypes` is deliberately left empty here: Photo mode
            // should not pay for detection, and the types can only be read off
            // `availableMetadataObjectTypes` once the output has a connection,
            // which is what `commitConfiguration()` above just gave it.
            self.session.startRunning()
            DispatchQueue.main.async {
                self.configured = true
                self.status = .ready
            }
        }
    }

    private func resume() {
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: Barcode scanning

    /// Start looking for a symbol. Nothing happens on a device with no camera —
    /// there the sheet takes the simulated path instead, which never calls this.
    func beginScanning() {
        guard configured else { return }
        acceptedCode = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.hasAccepted = false
            self.resetStreak()
            let available = Set(self.metadataOutput.availableMetadataObjectTypes)
            let types = Self.wantedSymbologies.filter { available.contains($0) }
            self.metadataOutput.metadataObjectTypes = types
            DispatchQueue.main.async {
                self.isScanning = !types.isEmpty
                self.scanUnsupported = types.isEmpty
            }
        }
    }

    /// Stop looking. Called when the mode changes, when a read is accepted and
    /// when the sheet goes away, so the output is never left running behind a
    /// screen that is no longer scanning.
    func endScanning() {
        guard configured else { return }
        isScanning = false
        queue.async { [weak self] in
            guard let self else { return }
            self.metadataOutput.metadataObjectTypes = []
            self.hasAccepted = false
            self.resetStreak()
        }
    }

    private func resetStreak() {
        streakCode = nil
        streakCount = 0
        streakBegan = 0
        streakSeen = 0
    }

    /// A cheap sanity check on a payload before it is treated as a product code.
    ///
    /// The scanner already verifies the check digit on the symbologies it
    /// decodes, so on a real read this is nearly always true. It earns its keep
    /// on the simulated path, where a code is chosen by hand and a wrong digit
    /// should be refused before anything is looked up.
    ///
    /// Only GTIN-12/13/14 get the checksum. Eight-digit codes are left at a
    /// digits-only check on purpose: a UPC-E check digit belongs to the expanded
    /// UPC-A form, so running mod-10 over the eight printed digits would throw
    /// away perfectly good reads.
    ///
    /// Non-numeric payloads are ignored rather than forwarded. Code 128 can
    /// carry anything, but the lookup on the other side of this is keyed by
    /// GTIN, so a word is not a product code and there is nowhere to send it.
    static func isPlausibleBarcode(_ raw: String) -> Bool {
        let digits = raw.trimmingCharacters(in: .whitespaces)
        guard (8...14).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        guard (12...14).contains(digits.count) else { return true }
        return hasValidCheckDigit(digits)
    }

    /// GS1 mod-10: weight the digits 1, 3, 1, 3 … leftwards from the check digit
    /// itself, and the lot has to come to a multiple of ten. A GTIN carries its
    /// own arithmetic, which is why a mistyped one can be caught without asking
    /// anybody anything.
    private static func hasValidCheckDigit(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count else { return false }
        let sum = values.reversed().enumerated().reduce(0) { total, pair in
            total + pair.element * (pair.offset.isMultiple(of: 2) ? 1 : 3)
        }
        return sum.isMultiple(of: 10)
    }

    func capture(_ completion: @escaping (UIImage?) -> Void) {
        guard status == .ready, !isCapturing else {
            completion(nil)
            return
        }
        isCapturing = true
        pending = completion
        let settings = AVCapturePhotoSettings()
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension MealCameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            let finish = self.pending
            self.pending = nil
            finish?(image)
        }
    }
}

extension MealCameraModel: AVCaptureMetadataOutputObjectsDelegate {
    /// Runs on `queue`, once per captured frame, and keeps firing for as long as
    /// the symbol stays in view. Everything below is a debounce: the first read
    /// wins, but only after it has proved it is the same read three frames
    /// running and a quarter of a second apart.
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasAccepted else { return }

        let payload = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .compactMap(\.stringValue)
            .first { Self.isPlausibleBarcode($0) }

        // A frame with nothing readable in it is left alone rather than treated
        // as a break in the run: focus hunting drops frames constantly, and
        // throwing the run away on each dropped frame means never accepting
        // anything. The gap check below is what ends a run that has really
        // stopped, because it measures time rather than counting frames.
        guard let payload else { return }

        let now = Date().timeIntervalSinceReferenceDate
        if streakCode == payload, now - streakSeen <= Self.streakGapSeconds {
            streakCount += 1
        } else {
            streakCode = payload
            streakCount = 1
            streakBegan = now
        }
        streakSeen = now

        guard streakCount >= Self.requiredFrames,
              now - streakBegan >= Self.settleSeconds else { return }

        // Accepted. The flag is set here, synchronously on the delegate's own
        // serial queue and before anything asynchronous happens, which is what
        // makes a second delivery impossible rather than merely unlikely.
        hasAccepted = true
        metadataOutput.metadataObjectTypes = []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScanning = false
            self.acceptedCode = payload
        }
    }
}

// MARK: - Preview layer

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Sample dishes

/// What the simulated viewfinder points at when there is no camera. One dish per
/// branch of the `MealEntry` machine, so every path has something to shoot.
///
/// Drawn by scripts/make-sample-meals.swift — illustrations, not photographs,
/// and labelled as such on screen.
struct SampleDish: Identifiable, Equatable {
    let id: String
    let name: String
    let note: String

    var image: UIImage? { UIImage(named: id) }

    static let all: [SampleDish] = [
        .init(id: "meal-salmon", name: "Grilled salmon and rice",
              note: "two items a classifier would clear"),
        .init(id: "meal-noodles", name: "Mixed noodle plate",
              note: "a portion that is genuinely hard to judge"),
        .init(id: "meal-unfamiliar", name: "Unfamiliar stew",
              note: "nothing a reference entry would match"),
    ]
}

// MARK: - Sample barcodes

/// What the simulated scanner can read, for the same reason `SampleDish` exists:
/// a simulator has no camera, and a path that cannot be exercised on a simulator
/// is a path nobody checks.
///
/// The codes are real, because a made-up barcode resolves to nothing and would
/// teach the demo the wrong lesson. Each one is described by exactly what is
/// known about it and no more — one has been checked against Open Food Facts,
/// one has not, and one is arithmetically broken on purpose.
struct SampleBarcode: Identifiable, Equatable {
    /// The digits, which are also the identity — there is no second code with
    /// the same number.
    let id: String
    let name: String
    let note: String
    /// A genuine Code 128 encoding of `id`, generated once when `all` is first
    /// touched. See `simulatedBarcodeViewfinder` for what it is and is not.
    let symbol: UIImage?

    var digits: String { id }

    /// Runs the same check the real scanner's payload runs, which is how the
    /// deliberately broken sample gets refused rather than looked up.
    var isPlausible: Bool { MealCameraModel.isPlausibleBarcode(id) }

    init(digits: String, name: String, note: String) {
        self.id = digits
        self.name = name
        self.note = note
        self.symbol = Self.code128(digits)
    }

    static func == (lhs: SampleBarcode, rhs: SampleBarcode) -> Bool { lhs.id == rhs.id }

    static let all: [SampleBarcode] = [
        .init(digits: "3017620422003",
              name: "Nutella, 400 g jar",
              note: "checked: Open Food Facts has a row for this one"),
        .init(digits: "9300675024235",
              name: "An Australian-prefixed EAN-13",
              note: "well formed, but Kairo has not looked it up — use it to see what "
                  + "happens when the table has no row"),
        .init(digits: "3017620422004",
              name: "The Nutella code with one digit wrong",
              note: "the check digit does not add up, so it is refused before any lookup"),
    ]

    /// Core Image's Code 128 generator, which encodes the digits properly rather
    /// than drawing decorative stripes. Nil is a legitimate answer — the caller
    /// falls back to the digits in text.
    private static func code128(_ digits: String) -> UIImage? {
        guard let message = digits.data(using: .ascii),
              let filter = CIFilter(name: "CICode128BarcodeGenerator") else { return nil }
        filter.setValue(message, forKey: "inputMessage")
        filter.setValue(6.0, forKey: "inputQuietSpace")
        guard let output = filter.outputImage else { return nil }
        // Generated at one point per module, so it is scaled up before it is
        // rasterised; nearest-neighbour on the way out keeps the bars crisp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - The capture screen

struct MealCameraSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var camera = MealCameraModel()
    @State private var dish = SampleDish.all[0]
    @State private var simulating = false
    @State private var flash = false
    @State private var mode: CaptureMode = .photo
    @State private var sample = SampleBarcode.all[0]
    /// The code that has been read and is about to be handed over. Held for a
    /// beat so the confirmation is actually seen.
    @State private var confirmed: String?
    /// Set when a chosen code fails its check digit, so the refusal is visible
    /// rather than a button that looks broken.
    @State private var refused: String?

    let onPhoto: (UIImage) -> Void
    /// Non-nil turns Barcode mode on. Nil leaves this screen exactly as it was:
    /// a scan with nowhere to go would be a control that does nothing, so the
    /// mode is not offered unless somebody is listening for the code.
    var onBarcode: ((String) -> Void)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .preparing:
                KairoLoader(size: 54, label: "Waking the camera")
            case .ready:
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .overlay { guide }
                Scrim()
                liveControls
            case .denied:
                permissionState
                closeButton
            case .unavailable:
                simulatedViewfinder
                Scrim()
                simulatedControls
            }

            // The shutter flash, on both paths, because it is the only feedback
            // that says the moment was taken rather than missed.
            if flash {
                Color.white.ignoresSafeArea().transition(.opacity)
            }

            if let confirmed { readConfirmation(confirmed) }
        }
        .animation(.easeOut(duration: 0.12), value: flash)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: confirmed)
        .task { camera.prepare() }
        .onChange(of: mode) { _, now in
            refused = nil
            apply(now)
        }
        // The mode can be chosen while the camera is still waking up, so the
        // decision is re-applied once there is a session to apply it to.
        .onChange(of: camera.status) { _, _ in apply(mode) }
        .onChange(of: camera.acceptedCode) { _, code in
            guard let code else { return }
            settle(code)
        }
        .onDisappear {
            camera.endScanning()
            camera.stop()
        }
    }

    /// Scanning costs frames, so the metadata output only runs in Barcode mode.
    private func apply(_ mode: CaptureMode) {
        guard camera.status == .ready else { return }
        switch mode {
        case .photo:   camera.endScanning()
        case .barcode: camera.beginScanning()
        }
    }

    @ViewBuilder private var guide: some View {
        switch mode {
        case .photo:   FramingGuide()
        case .barcode: BarcodeGuide(active: camera.isScanning && confirmed == nil)
        }
    }

    // MARK: live

    private var liveControls: some View {
        VStack {
            closeRow

            if mode == .barcode { scanStatus.padding(.top, 2) }

            Spacer()

            VStack(spacing: 16) {
                switch mode {
                case .photo:
                    shutter { take() }
                case .barcode:
                    // No shutter in Barcode mode: scanning is continuous and the
                    // first stable read wins, so a button to press would only be
                    // a button that does nothing.
                    barcodeHint
                }
                modeSwitch
            }
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder private var scanStatus: some View {
        if camera.scanUnsupported {
            Pill(text: "this camera reports no barcode formats",
                 icon: "exclamationmark.triangle", tint: Kairo.coral)
        } else if camera.isScanning {
            Pill(text: "scanning · hold it steady", icon: "barcode.viewfinder", tint: Kairo.teal)
        }
    }

    private var barcodeHint: some View {
        Text("A barcode is the only path here that ends in a measured number — the "
             + "manufacturer's own declared figures, from a published row. Point at "
             + "the pack; Kairo takes the first read that holds still.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.7), radius: 6)
            .padding(.horizontal, 32)
    }

    private func take() {
        camera.capture { image in
            guard let image else { return }
            fire { onPhoto(image) }
        }
    }

    // MARK: accepting a read

    /// The visible half of a successful read. The haptic fires at the same
    /// moment; neither is enough alone — one is missed in a noisy supermarket,
    /// the other by anybody who has haptics turned off.
    private func readConfirmation(_ code: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.88))
                .frame(width: 54, height: 54)
                .background(Circle().fill(Kairo.leaf))
            Text("Barcode read").font(.kairoHeadline).foregroundStyle(Kairo.ink)
            Text(code).font(.kairoMono).foregroundStyle(Kairo.inkSoft)
            Text("Looking this one up in the food composition table.")
                .font(.caption)
                .foregroundStyle(Kairo.inkFaint)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .kairoCard(tint: Kairo.leaf)
        .padding(.horizontal, 44)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        // Digit by digit, because "three trillion" is not what was read.
        .accessibilityLabel("Barcode read: "
                            + code.map(String.init).joined(separator: " "))
    }

    /// Accept a read: haptic, then the confirmation stays up for a beat before
    /// the code is handed over. The delay is not decoration — without it the
    /// sheet vanishes and the user never learns which code was taken.
    private func settle(_ code: String) {
        guard confirmed == nil else { return }
        confirmed = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            confirmed = nil
            onBarcode?(code)
            dismiss()
        }
    }

    // MARK: mode switch

    @ViewBuilder private var modeSwitch: some View {
        if onBarcode != nil { CaptureModeSwitch(mode: $mode) }
    }

    // MARK: simulated
    //
    // The same viewfinder, the same framing guide and the same shutter, with a
    // still standing in for the sensor. It is labelled, because a demo that
    // looks like a live camera when it is not is its own small lie.
    //
    // Barcode mode gets the same treatment for the same reason: the simulator
    // has no camera, and the barcode path is the one that matters most, so it
    // has to be exercisable without hardware — labelled just as plainly.

    @ViewBuilder private var simulatedViewfinder: some View {
        switch mode {
        case .photo:   simulatedDishViewfinder
        case .barcode: simulatedBarcodeViewfinder
        }
    }

    @ViewBuilder private var simulatedControls: some View {
        switch mode {
        case .photo:   simulatedPhotoControls
        case .barcode: simulatedBarcodeControls
        }
    }

    private var simulatedDishViewfinder: some View {
        ZStack {
            if let image = dish.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .id(dish.id)
            }
            FramingGuide()
        }
        .animation(.easeInOut(duration: 0.25), value: dish)
    }

    private var simulatedPhotoControls: some View {
        VStack {
            closeRow

            Pill(text: "simulated · no camera on this device",
                 icon: "camera.metering.unknown", tint: Kairo.amber)
                .padding(.top, 2)

            Spacer()

            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(dish.name)
                        .font(.kairoHeadline)
                        .foregroundStyle(.white)
                    Text(dish.note)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .shadow(color: .black.opacity(0.6), radius: 6)

                HStack(spacing: 12) {
                    ForEach(SampleDish.all) { option in
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                dish = option
                            }
                        } label: {
                            thumbnail(option)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(dish == option ? [.isButton, .isSelected]
                                                               : .isButton)
                    }
                }

                shutter {
                    guard let image = dish.image, !simulating else { return }
                    simulating = true
                    fire {
                        simulating = false
                        onPhoto(image)
                    }
                }

                modeSwitch
            }
            .padding(.bottom, 30)
        }
    }

    /// Nothing to point at, so the "viewfinder" shows the code that is about to
    /// be handed over — genuinely encoded rather than drawn as decorative
    /// stripes, which means a second phone can read it off this screen.
    ///
    /// It is a Code 128 rendering of those digits, not the EAN-13 that is
    /// actually printed on the pack. The caption says so, because a symbol that
    /// looks like the one on the jar and is not would be the same small lie as a
    /// simulated viewfinder pretending to be live.
    private var simulatedBarcodeViewfinder: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                if let symbol = sample.symbol {
                    Image(uiImage: symbol)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 250, maxHeight: 84)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white))
                } else {
                    Text(sample.digits)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                Text("the digits below, encoded as Code 128 — not the EAN-13 printed "
                     + "on the pack")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .offset(y: -20)
            .id(sample.id)
            .transition(.opacity)

            BarcodeGuide(active: false)
        }
        .animation(.easeInOut(duration: 0.22), value: sample)
    }

    private var simulatedBarcodeControls: some View {
        VStack {
            closeRow

            Pill(text: "simulated scan · no camera on this device",
                 icon: "barcode.viewfinder", tint: Kairo.amber)
                .padding(.top, 2)

            Spacer()

            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(sample.name)
                        .font(.kairoHeadline)
                        .foregroundStyle(.white)
                    Text(sample.note)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(.horizontal, 28)

                VStack(spacing: 8) {
                    ForEach(SampleBarcode.all) { option in
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                sample = option
                                refused = nil
                            }
                        } label: {
                            sampleRow(option)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)

                if let refused {
                    Text("\(refused) does not pass its own check digit, so Kairo will not "
                         + "look it up. A GTIN carries that arithmetic with it, and a code "
                         + "that fails it is a misread rather than a product.")
                        .font(.caption)
                        .foregroundStyle(Kairo.coral)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                }

                Button("Scan this code") { simulateScan() }
                    .buttonStyle(.kairoProminent(Kairo.teal))
                    .padding(.horizontal, 44)
                    .disabled(confirmed != nil)

                modeSwitch
            }
            .padding(.bottom, 30)
        }
        .animation(.easeOut(duration: 0.2), value: refused)
    }

    /// The simulated read goes through the same acceptance as a real one — the
    /// check digit, the haptic, the confirmation card, the same callback. The
    /// only thing missing is the camera, and the label above says as much.
    private func simulateScan() {
        guard confirmed == nil else { return }
        guard sample.isPlausible else {
            refused = sample.digits
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        refused = nil
        settle(sample.digits)
    }

    private func sampleRow(_ option: SampleBarcode) -> some View {
        let selected = sample == option
        return HStack(spacing: 10) {
            Image(systemName: option.isPlausible ? "barcode" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(option.isPlausible ? Kairo.teal : Kairo.coral)
            Text(option.digits)
                .font(.kairoMono)
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Kairo.amber)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay {
            Capsule().strokeBorder(selected ? Kairo.amber : .white.opacity(0.18),
                                   lineWidth: selected ? 1.6 : 0.5)
        }
        .accessibilityLabel("\(option.name), "
                            + option.digits.map(String.init).joined(separator: " "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func thumbnail(_ option: SampleDish) -> some View {
        let selected = dish == option
        return Group {
            if let image = option.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black.opacity(0.5)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(selected ? Kairo.amber : .white.opacity(0.45),
                                  lineWidth: selected ? 2.5 : 1)
        }
        .scaleEffect(selected ? 1.08 : 1)
    }

    // MARK: shared chrome

    private var closeRow: some View {
        HStack {
            closeButtonLabel
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var closeButton: some View {
        VStack { closeRow; Spacer() }
    }

    private var closeButtonLabel: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.black.opacity(0.45)))
        }
        .accessibilityLabel("Close the camera")
    }

    private func shutter(_ action: @escaping () -> Void) -> some View {
        let busy = camera.isCapturing || simulating
        return Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3.5)
                    .frame(width: 74, height: 74)
                Circle().fill(Kairo.amber)
                    .frame(width: 58, height: 58)
                    .scaleEffect(busy ? 0.86 : 1)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: busy)
        }
        .disabled(busy)
        .accessibilityLabel("Take the photo")
    }

    /// Flash, then hand the photo over on the next beat, so the capture is seen
    /// before the sheet goes away.
    private func fire(_ then: @escaping () -> Void) {
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            flash = false
            then()
            dismiss()
        }
    }

    // MARK: denied

    private var permissionState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.slash")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Kairo.coral)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Kairo.coral.opacity(0.14)))
            Text("Camera access is off").font(.kairoHeadline).foregroundStyle(Kairo.ink)
            Text("Kairo opens the camera only when you tap the shutter, and the photo "
                 + "stays on your iPhone. You can turn access on in Settings.")
                .font(.kairoCaption)
                .foregroundStyle(Kairo.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.kairoProminent(Kairo.coral))
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .kairoCard(tint: Kairo.coral)
        .padding(.horizontal, 24)
    }
}

// MARK: - Modes

/// Photo or barcode. Two modes of one screen, because they are two answers to
/// the same question with very different standing: a photograph ends in an
/// estimate, a barcode ends in the manufacturer's declared numbers.
private enum CaptureMode: String, CaseIterable, Identifiable {
    case photo, barcode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo:   "Photo"
        case .barcode: "Barcode"
        }
    }

    var icon: String {
        switch self {
        case .photo:   "camera"
        case .barcode: "barcode.viewfinder"
        }
    }
}

/// The segmented control, in Kairo's vocabulary rather than UIKit's: a capsule
/// track over the viewfinder with the live segment carried on amber, which is
/// the colour this app uses for attention actually being spent.
private struct CaptureModeSwitch: View {
    @Binding var mode: CaptureMode
    @Namespace private var slider

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { option in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        mode = option
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.icon)
                            .font(.system(size: 11, weight: .bold))
                        Text(option.title)
                            .font(.kairoLabel).tracking(0.6)
                    }
                    .foregroundStyle(mode == option ? Color.black.opacity(0.88)
                                                    : Color.white.opacity(0.75))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background {
                        if mode == option {
                            Capsule().fill(Kairo.amber)
                                .matchedGeometryEffect(id: "mode", in: slider)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.title) mode")
                .accessibilityAddTraits(mode == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
    }
}

/// Darkens the top and bottom only. Without it the controls and the framing
/// brackets are illegible over anything bright — a white plate, a sunlit table —
/// and that is as true of the real camera as of the simulated one.
private struct Scrim: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.55), location: 0),
            .init(color: .clear, location: 0.26),
            .init(color: .clear, location: 0.58),
            .init(color: .black.opacity(0.70), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Corner brackets rather than a full box: the meal should be inside them, but
/// the capture is not cropped, so a hard frame would be a promise it does not keep.
private struct FramingGuide: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.78
            let rect = CGRect(x: (geo.size.width - side) / 2,
                              y: (geo.size.height - side) / 2 - 20,
                              width: side, height: side)
            ZStack {
                ForEach(0..<4, id: \.self) { corner in
                    bracket(corner)
                        .position(x: corner % 2 == 0 ? rect.minX + 22 : rect.maxX - 22,
                                  y: corner < 2 ? rect.minY + 22 : rect.maxY - 22)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func bracket(_ corner: Int) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 26))
            p.addLine(to: CGPoint(x: 0, y: 4))
            p.addQuadCurve(to: CGPoint(x: 4, y: 0), control: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 26, y: 0))
        }
        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .frame(width: 26, height: 26)
        .scaleEffect(x: corner % 2 == 0 ? 1 : -1, y: corner < 2 ? 1 : -1)
        .shadow(color: .black.opacity(0.35), radius: 4)
    }
}

/// The barcode window: wide and landscape, because a barcode is wide and a
/// square guide would have people turning the phone.
///
/// Unlike `FramingGuide` this one is a closed outline rather than corner
/// brackets — here the user genuinely needs to know where to aim. What it is
/// *not* is a crop: the whole frame is scanned, and no `rectOfInterest` is
/// pinned to this rectangle. A guide that claimed bounds the scanner did not
/// honour would be worse than a guide that is honestly just advice.
private struct BarcodeGuide: View {
    /// Drives the sweep, and is false once a read has been accepted, so the line
    /// stops the instant the scanning does.
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.84, 420)
            let height = width * 0.42
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.85),
                              style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: width, height: height)
                .overlay { if active { scanLine(width: width, height: height) } }
                .shadow(color: .black.opacity(0.35), radius: 4)
                .position(x: geo.size.width / 2, y: geo.size.height / 2 - 20)
        }
        .allowsHitTesting(false)
    }

    /// Reduce Motion gets a still line. The sweep only says "still looking",
    /// and that message is not worth moving pixels somebody asked us to leave
    /// alone.
    private func scanLine(width: CGFloat, height: CGFloat) -> some View {
        let travel = (height - 10) / 2
        return Capsule()
            .fill(Kairo.amber)
            .frame(width: width - 26, height: 2.5)
            .shadow(color: Kairo.amber.opacity(0.8), radius: 6)
            .offset(y: reduceMotion ? 0 : (sweep ? travel : -travel))
            .animation(reduceMotion ? nil
                                    : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                       value: sweep)
            .onAppear { sweep = true }
    }
}
