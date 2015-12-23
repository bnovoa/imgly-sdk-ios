//
//  CameraController.swift
//  imglyKit
//
//  Created by Sascha Schwabbauer on 15/05/15.
//  Copyright (c) 2015 9elements GmbH. All rights reserved.
//

import Foundation
import AVFoundation
import OpenGLES
import GLKit
import CoreMotion

struct SDKVersion: Comparable, CustomStringConvertible {
    let majorVersion: Int
    let minorVersion: Int
    let patchVersion: Int

    var description: String {
        return "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}

func == (lhs: SDKVersion, rhs: SDKVersion) -> Bool {
    return (lhs.majorVersion == rhs.majorVersion) && (lhs.minorVersion == rhs.minorVersion) && (lhs.patchVersion == rhs.patchVersion)
}

func < (lhs: SDKVersion, rhs: SDKVersion) -> Bool {
    if lhs.majorVersion < rhs.majorVersion {
        return true
    } else if lhs.majorVersion > rhs.majorVersion {
        return false
    }

    if lhs.minorVersion < rhs.minorVersion {
        return true
    } else if lhs.minorVersion > rhs.minorVersion {
        return false
    }

    if lhs.patchVersion < rhs.patchVersion {
        return true
    } else if lhs.patchVersion > rhs.patchVersion {
        return false
    }

    return false
}

let CurrentSDKVersion = IMGLYSDKVersion(majorVersion: 2, minorVersion: 4, patchVersion: 1)

private let kIndicatorSize = CGFloat(75)
private var capturingStillImageContext = 0
private var sessionRunningAndDeviceAuthorizedContext = 0
private var focusAndExposureContext = 0

@objc(IMGLYCameraControllerDelegate) public protocol CameraControllerDelegate: class {
    optional func cameraControllerDidStartCamera(cameraController: CameraController)
    optional func cameraControllerDidStopCamera(cameraController: CameraController)
    optional func cameraControllerDidStartStillImageCapture(cameraController: CameraController)
    optional func cameraControllerDidFailAuthorization(cameraController: CameraController)
    optional func cameraController(cameraController: CameraController, didChangeToFlashMode flashMode: AVCaptureFlashMode)
    optional func cameraController(cameraController: CameraController, didChangeToTorchMode torchMode: AVCaptureTorchMode)
    optional func cameraControllerDidCompleteSetup(cameraController: CameraController)
    optional func cameraController(cameraController: CameraController, willSwitchToCameraPosition cameraPosition: AVCaptureDevicePosition)
    optional func cameraController(cameraController: CameraController, didSwitchToCameraPosition cameraPosition: AVCaptureDevicePosition)
    optional func cameraController(cameraController: CameraController, willSwitchToRecordingMode recordingMode: RecordingMode)
    optional func cameraController(cameraController: CameraController, didSwitchToRecordingMode recordingMode: RecordingMode)
    optional func cameraControllerAnimateAlongsideFirstPhaseOfRecordingModeSwitchBlock(cameraController: CameraController) -> (() -> Void)
    optional func cameraControllerAnimateAlongsideSecondPhaseOfRecordingModeSwitchBlock(cameraController: CameraController) -> (() -> Void)
    optional func cameraControllerFirstPhaseOfRecordingModeSwitchAnimationCompletionBlock(cameraController: CameraController) -> (() -> Void)
    optional func cameraControllerDidStartRecording(cameraController: CameraController)
    optional func cameraController(cameraController: CameraController, recordedSeconds seconds: Int)
    optional func cameraControllerDidFinishRecording(cameraController: CameraController, fileURL: NSURL)
    optional func cameraControllerDidFailRecording(cameraController: CameraController, error: NSError?)
}

public typealias TakePhotoBlock = (UIImage?, NSError?) -> Void
public typealias RecordVideoBlock = (NSURL?, NSError?) -> Void

private let kTempVideoFilename = "recording.mov"

public class CameraController: NSObject {

    // MARK: - Properties

    /// The response filter that is applied to the live-feed.
    public var effectFilter: EffectFilter = NoneFilter()
    public let previewView: UIView
    public var previewContentMode: UIViewContentMode  = .ScaleAspectFit
    public var tapToFocusEnabled = true

    public var allowedCameraPositions: [AVCaptureDevicePosition] = [ .Back, .Front ] {
        didSet {
            if allowedCameraPositions.count == 0 {
                fatalError("You have to allow at least one camera position (e.g. .Back)")
            }

            /// Ensure that the only allowed camera position is available
            if allowedCameraPositions.count == 1 {
                let videoDevices = AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo)
                if videoDevices.count == 1 {
                    if allowedCameraPositions.contains(.Back) && videoDevices.first!.position != .Back {
                        print("Device doesn't feature the allowed camera position (Back), falling back to use the available camera.")
                        allowedCameraPositions = [ .Front ]
                    }
                    if allowedCameraPositions.contains(.Front) && videoDevices.first!.position != .Front {
                        print("Device doesn't feature the allowed camera position (Front), falling back to use the available camera.")
                        allowedCameraPositions = [ .Back ]
                    }
                }
            }
        }
    }

    public var allowedFlashModes: [AVCaptureFlashMode] = [.On, .Off, .Auto] {
        didSet {
            if allowedFlashModes.count == 0 {
                fatalError("You have to allow at least one flash mode (e.g. .Off)")
            }
        }
    }

    public var allowedTorchModes: [AVCaptureTorchMode] = [.On, .Off, .Auto] {
        didSet {
            if allowedTorchModes.count == 0 {
                fatalError("You have to allow at least one torch mode (e.g. .Off")
            }
        }
    }

    public weak var delegate: CameraControllerDelegate?
    public let tapGestureRecognizer = UITapGestureRecognizer()

    dynamic private let session = AVCaptureSession()
    private let sessionQueue = dispatch_queue_create("capture_session_queue", nil)
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    dynamic private var stillImageOutput: AVCaptureStillImageOutput?
    private var runtimeErrorHandlingObserver: NSObjectProtocol?
    dynamic private var deviceAuthorized = false
    private var glContext: EAGLContext?
    private var ciContext: CIContext?
    private var videoPreviewView: GLKView?
    private var setupComplete = false
    private var videoPreviewFrame = CGRectZero
    private let focusIndicatorLayer = CALayer()
    private let maskIndicatorLayer = CALayer()
    private let upperMaskDarkenLayer = CALayer()
    private let lowerMaskDarkenLayer = CALayer()
    private var focusIndicatorFadeOutTimer: NSTimer?
    private var focusIndicatorAnimating = false
    private let motionManager: CMMotionManager = {
        let motionManager = CMMotionManager()
        motionManager.accelerometerUpdateInterval = 0.2
        return motionManager
        }()
    private let motionManagerQueue = NSOperationQueue()
    private var captureVideoOrientation: AVCaptureVideoOrientation?

    dynamic private var sessionRunningAndDeviceAuthorized: Bool {
        return session.running && deviceAuthorized
    }

    public var squareMode: Bool

    // Video Recording
    private var assetWriter: AVAssetWriter?
    private var assetWriterAudioInput: AVAssetWriterInput?
    private var assetWriterVideoInput: AVAssetWriterInput?
    private var assetWriterInputPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var currentVideoDimensions: CMVideoDimensions?
    // swiftlint:disable variable_name_max_length
    private var currentAudioSampleBufferFormatDescription: CMFormatDescriptionRef?
    // swiftlint:enable variable_name_max_length
    private var backgroundRecordingID: UIBackgroundTaskIdentifier?
    private var videoWritingStarted = false
    private var videoWritingStartTime: CMTime?
    private var currentVideoTime: CMTime?
    private var timeUpdateTimer: NSTimer?
    public var maximumVideoLength: Int?

    // MARK: - Initializers

    init(previewView: UIView) {
        self.previewView = previewView
        self.squareMode = false
        super.init()
    }

    // MARK: - NSKeyValueObserving

    class func keyPathsForValuesAffectingSessionRunningAndDeviceAuthorized() -> Set<String> {
        return Set(["session.running", "deviceAuthorized"])
    }

    public override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        if context == &capturingStillImageContext {
            let capturingStillImage = change?[NSKeyValueChangeNewKey]?.boolValue

            if let isCapturingStillImage = capturingStillImage where isCapturingStillImage {
                self.delegate?.cameraControllerDidStartStillImageCapture?(self)
            }
        } else if context == &sessionRunningAndDeviceAuthorizedContext {
            let running = change?[NSKeyValueChangeNewKey]?.boolValue

            if let isRunning = running {
                if isRunning {
                    self.delegate?.cameraControllerDidStartCamera?(self)
                } else {
                    self.delegate?.cameraControllerDidStopCamera?(self)
                }
            }
        } else if context == &focusAndExposureContext {
            dispatch_async(dispatch_get_main_queue()) {
                self.updateFocusIndicatorLayer()
            }
        } else {
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }
    }

    // MARK: - SDK

    private func versionComponentsFromString(version: String) -> (majorVersion: Int, minorVersion: Int, patchVersion: Int)? {
        let versionComponents = version.componentsSeparatedByString(".")
        if versionComponents.count == 3 {
            if let major = Int(versionComponents[0]), minor = Int(versionComponents[1]), patch = Int(versionComponents[2]) {
                return (major, minor, patch)
            }
        }

        return nil
    }

    private func checkSDKVersion() {
        let appIdentifier = NSBundle.mainBundle().infoDictionary?["CFBundleIdentifier"] as? String
        if let appIdentifier = appIdentifier, url = NSURL(string: "https://www.photoeditorsdk.com/version.json?type=ios&app=\(appIdentifier)") {
            let task = NSURLSession.sharedSession().dataTaskWithURL(url) { data, response, error in
                if let data = data {
                    do {
                        let json = try NSJSONSerialization.JSONObjectWithData(data, options: []) as? [String: AnyObject]

                        if let json = json, version = json["version"] as? String, versionComponents = self.versionComponentsFromString(version) {
                            let remoteVersion = SDKVersion(majorVersion: versionComponents.majorVersion, minorVersion: versionComponents.minorVersion, patchVersion: versionComponents.patchVersion)

                            if kCurrentSDKVersion < remoteVersion {
                                print("Your version of the img.ly SDK is outdated. You are using version \(kCurrentSDKVersion), the latest available version is \(remoteVersion). Please consider updating.")
                            }
                        }
                    } catch {

                    }
                }
            }

            task.resume()
        }
    }

    // MARK: - Authorization

    public func checkDeviceAuthorizationStatus() {
        AVCaptureDevice.requestAccessForMediaType(AVMediaTypeVideo, completionHandler: { granted in
            if granted {
                self.deviceAuthorized = true
            } else {
                self.delegate?.cameraControllerDidFailAuthorization?(self)
                self.deviceAuthorized = false
            }
        })
    }

    // MARK: - Camera

    /// Use this property to determine if more than one camera is available and if more than one camera is allowed.
    /// Within the SDK this property is used to determine if the toggle button is visible.
    public var moreThanOneCameraPresent: Bool {
        let videoDevices = AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo)
        return videoDevices.count > 1 && allowedCameraPositions.count > 1
    }

    public func toggleCameraPosition() {
        if let device = videoDeviceInput?.device {
            let nextPosition: AVCaptureDevicePosition

            switch device.position {
            case .Front:
                nextPosition = .Back
            case .Back:
                nextPosition = .Front
            default:
                nextPosition = .Back
            }

            delegate?.cameraController?(self, willSwitchToCameraPosition: nextPosition)
            focusIndicatorLayer.hidden = true

            let sessionGroup = dispatch_group_create()

            if let videoPreviewView = videoPreviewView {
                let (snapshotWithBlur, snapshot) = addSnapshotViewsToVideoPreviewView(videoPreviewView)

                // Transitioning between the regular snapshot and the blurred snapshot, this automatically removes `snapshot` and adds `snapshotWithBlur` to the view hierachy
                UIView.transitionFromView(snapshot, toView: snapshotWithBlur, duration: 0.4, options: [.TransitionFlipFromLeft, .CurveEaseOut], completion: { _ in
                    // Wait for camera to toggle
                    dispatch_group_notify(sessionGroup, dispatch_get_main_queue()) {
                        // Giving the preview view a bit of time to redraw first
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(0.05 * Double(NSEC_PER_SEC))), dispatch_get_main_queue()) {
                            // Cross fading between blur and live preview, this sets `snapshotWithBlur.hidden` to `true` and `videoPreviewView.hidden` to false
                            UIView.transitionFromView(snapshotWithBlur, toView: videoPreviewView, duration: 0.2, options: [.TransitionCrossDissolve, .ShowHideTransitionViews], completion: { _ in
                                // Deleting the blurred snapshot
                                snapshotWithBlur.removeFromSuperview()
                            })
                        }
                    }
                })
            }

            dispatch_async(sessionQueue) {
                dispatch_group_enter(sessionGroup)
                self.session.beginConfiguration()
                self.session.removeInput(self.videoDeviceInput)

                self.removeObserversFromInputDevice()
                self.setupVideoInputsForPreferredCameraPosition(nextPosition)
                self.addObserversToInputDevice()

                self.session.commitConfiguration()
                dispatch_group_leave(sessionGroup)

                self.delegate?.cameraController?(self, didSwitchToCameraPosition: nextPosition)
            }
        }
    }

    // MARK: - Mask layer
    private func setupMaskLayers() {
        setupMaskIndicatorLayer()
        setupUpperMaskDarkenLayer()
        setupLowerMaskDarkenLayer()
    }

    private func setupMaskIndicatorLayer() {
        maskIndicatorLayer.borderColor = UIColor.whiteColor().CGColor
        maskIndicatorLayer.borderWidth = 1
        maskIndicatorLayer.frame.origin = CGPoint(x: 0, y: 0)
        maskIndicatorLayer.frame.size = CGSize(width: kIndicatorSize, height: kIndicatorSize)
        maskIndicatorLayer.hidden = true
        maskIndicatorLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        previewView.layer.addSublayer(maskIndicatorLayer)
    }

    private func setupUpperMaskDarkenLayer() {
        upperMaskDarkenLayer.borderWidth = 0
        upperMaskDarkenLayer.frame.origin = CGPoint(x: 0, y: 0)
        upperMaskDarkenLayer.frame.size = CGSize(width: kIndicatorSize, height: kIndicatorSize)
        upperMaskDarkenLayer.hidden = true
        upperMaskDarkenLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        upperMaskDarkenLayer.backgroundColor = UIColor(white: 0.0, alpha: 0.8).CGColor
        previewView.layer.addSublayer(upperMaskDarkenLayer)
    }

    private func setupLowerMaskDarkenLayer() {
        lowerMaskDarkenLayer.borderWidth = 0
        lowerMaskDarkenLayer.frame.origin = CGPoint(x: 0, y: 0)
        lowerMaskDarkenLayer.frame.size = CGSize(width: kIndicatorSize, height: kIndicatorSize)
        lowerMaskDarkenLayer.hidden = true
        lowerMaskDarkenLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        lowerMaskDarkenLayer.backgroundColor = UIColor(white: 0.0, alpha: 0.8).CGColor
        previewView.layer.addSublayer(lowerMaskDarkenLayer)
    }


    // MARK: - Square view

    /*
    Please note, the calculations in this method might look a bit weird.
    The reason is that the frame we are getting is rotated by 90 degree
    */
    private func updateSquareIndicatorView(newRect: CGRect) {
        let width = newRect.size.height / 2.0
        let height = width
        let top = newRect.origin.x + ((newRect.size.width / 2.0) - width) / 2.0
        let left = newRect.origin.y / 2.0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        maskIndicatorLayer.frame = CGRect(x: left, y: top, width: width, height: height).integral
        upperMaskDarkenLayer.frame = CGRect(x: left, y: 0, width: width, height: top - 1).integral
        // add extra space to the bottom to avoid a gab due to the lower bar animation
        lowerMaskDarkenLayer.frame = CGRect(x: left, y: top + height + 1, width: width, height: top * 2).integral
        CATransaction.commit()
    }

    public func showSquareMask() {
        maskIndicatorLayer.hidden = false
        upperMaskDarkenLayer.hidden = false
        lowerMaskDarkenLayer.hidden = false
    }

    public func hideSquareMask() {
        maskIndicatorLayer.hidden = true
        upperMaskDarkenLayer.hidden = true
        lowerMaskDarkenLayer.hidden = true
    }

    // MARK: - Flash

    /**
    Selects the next flash-mode. The order is taken from `availableFlashModes`.
    If the current device does not support a flash mode, this method uses the next flash mode that is supported or .Off.
    */
    public func selectNextFlashMode() {
        guard let device = videoDeviceInput?.device else {
            return
        }

        let currentFlashModeIndex = allowedFlashModes.indexOf(flashMode) ?? 0
        var nextFlashModeIndex = (currentFlashModeIndex + 1) % allowedFlashModes.count
        var nextFlashMode = allowedFlashModes[nextFlashModeIndex]
        var counter = 1

        while !device.isFlashModeSupported(nextFlashMode) {
            nextFlashModeIndex = (nextFlashModeIndex + 1) % allowedFlashModes.count
            nextFlashMode = allowedFlashModes[nextFlashModeIndex]
            counter++

            if counter >= allowedFlashModes.count {
                nextFlashMode = .Off
                break
            }
        }

        flashMode = nextFlashMode
    }

    public private(set) var flashMode: AVCaptureFlashMode {
        get {
            if let device = self.videoDeviceInput?.device {
                return device.flashMode
            } else {
                return .Off
            }
        }

        set {
            dispatch_async(sessionQueue) {
                var error: NSError?
                self.session.beginConfiguration()

                if let device = self.videoDeviceInput?.device {
                    do {
                        try device.lockForConfiguration()
                    } catch let error1 as NSError {
                        error = error1
                    } catch {
                        fatalError()
                    }
                    device.flashMode = newValue
                    device.unlockForConfiguration()
                }

                self.session.commitConfiguration()

                if let error = error {
                    print("Error changing flash mode: \(error.description)")
                    return
                }

                self.delegate?.cameraController?(self, didChangeToFlashMode: newValue)
            }
        }
    }

    // MARK: - Torch

    /**
    Selects the next torch-mode. The order is Auto->On->Off.
    If the current device does not support auto-torch, this method
    just toggles between on and off.
    */
    public func selectNextTorchMode() {
        guard let device = videoDeviceInput?.device else {
            return
        }

        let currentTorchModeIndex = allowedTorchModes.indexOf(torchMode) ?? 0
        var nextTorchModeIndex = (currentTorchModeIndex + 1) % allowedTorchModes.count
        var nextTorchMode = allowedTorchModes[nextTorchModeIndex]
        var counter = 1

        while !device.isTorchModeSupported(nextTorchMode) {
            nextTorchModeIndex = (nextTorchModeIndex + 1) % allowedTorchModes.count
            nextTorchMode = allowedTorchModes[nextTorchModeIndex]
            counter++

            if counter >= allowedTorchModes.count {
                nextTorchMode = .Off
                break
            }
        }

        torchMode = nextTorchMode
    }

    public private(set) var torchMode: AVCaptureTorchMode {
        get {
            if let device = self.videoDeviceInput?.device {
                return device.torchMode
            } else {
                return .Off
            }
        }

        set {
            dispatch_async(sessionQueue) {
                var error: NSError?
                self.session.beginConfiguration()

                if let device = self.videoDeviceInput?.device where device.isTorchModeSupported(newValue) {
                    do {
                        try device.lockForConfiguration()
                    } catch let error1 as NSError {
                        error = error1
                    } catch {
                        fatalError()
                    }
                    device.torchMode = newValue
                    device.unlockForConfiguration()
                }

                self.session.commitConfiguration()

                if let error = error {
                    print("Error changing torch mode: \(error.description)")
                    return
                }

                self.delegate?.cameraController?(self, didChangeToTorchMode: newValue)
            }
        }
    }

    // MARK: - Focus

    private func setupFocusIndicator() {
        focusIndicatorLayer.borderColor = UIColor.whiteColor().CGColor
        focusIndicatorLayer.borderWidth = 1
        focusIndicatorLayer.frame.size = CGSize(width: kIndicatorSize, height: kIndicatorSize)
        focusIndicatorLayer.hidden = true
        focusIndicatorLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        previewView.layer.addSublayer(focusIndicatorLayer)

        tapGestureRecognizer.addTarget(self, action: "tapped:")

        if let videoPreviewView = videoPreviewView {
            videoPreviewView.addGestureRecognizer(tapGestureRecognizer)
        }
    }

    private func showFocusIndicatorLayerAtLocation(location: CGPoint) {
        focusIndicatorFadeOutTimer?.invalidate()
        focusIndicatorFadeOutTimer = nil
        focusIndicatorAnimating = false

        CATransaction.begin()
        focusIndicatorLayer.opacity = 1
        focusIndicatorLayer.hidden = false
        focusIndicatorLayer.borderColor = UIColor.whiteColor().CGColor
        focusIndicatorLayer.frame.size = CGSize(width: kIndicatorSize, height: kIndicatorSize)
        focusIndicatorLayer.position = location
        focusIndicatorLayer.transform = CATransform3DIdentity
        focusIndicatorLayer.removeAllAnimations()
        CATransaction.commit()

        let resizeAnimation = CABasicAnimation(keyPath: "transform")
        resizeAnimation.fromValue = NSValue(CATransform3D: CATransform3DMakeScale(1.5, 1.5, 1))
        resizeAnimation.duration = 0.25
        focusIndicatorLayer.addAnimation(resizeAnimation, forKey: nil)
    }

    @objc private func tapped(recognizer: UITapGestureRecognizer) {
        if focusPointSupported || exposurePointSupported {
            if let videoPreviewView = videoPreviewView {
                let focusPointLocation = recognizer.locationInView(videoPreviewView)
                let scaleFactor = videoPreviewView.contentScaleFactor
                let videoFrame = CGRect(x: videoPreviewFrame.minX / scaleFactor, y: videoPreviewFrame.minY / scaleFactor, width: videoPreviewFrame.width / scaleFactor, height: videoPreviewFrame.height / scaleFactor)

                if CGRectContainsPoint(videoFrame, focusPointLocation) {
                    let focusIndicatorLocation = recognizer.locationInView(previewView)
                    showFocusIndicatorLayerAtLocation(focusIndicatorLocation)

                    var pointOfInterest = CGPoint(x: focusPointLocation.x / videoFrame.width, y: focusPointLocation.y / videoFrame.height)
                    pointOfInterest.x = 1 - pointOfInterest.x

                    if let device = videoDeviceInput?.device where device.position == .Front {
                        pointOfInterest.y = 1 - pointOfInterest.y
                    }

                    focusWithMode(.AutoFocus, exposeWithMode: .AutoExpose, atDevicePoint: pointOfInterest, monitorSubjectAreaChange: true)
                }
            }
        }
    }

    private var focusPointSupported: Bool {
        if let device = videoDeviceInput?.device {
            return device.focusPointOfInterestSupported && device.isFocusModeSupported(.AutoFocus) && device.isFocusModeSupported(.ContinuousAutoFocus) && tapToFocusEnabled
        }

        return false
    }

    private var exposurePointSupported: Bool {
        if let device = videoDeviceInput?.device {
            return device.exposurePointOfInterestSupported && device.isExposureModeSupported(.AutoExpose) && device.isExposureModeSupported(.ContinuousAutoExposure)
        }

        return false
    }

    private func focusWithMode(focusMode: AVCaptureFocusMode, exposeWithMode exposureMode: AVCaptureExposureMode, atDevicePoint point: CGPoint, monitorSubjectAreaChange: Bool) {
        dispatch_async(sessionQueue) {
            if let device = self.videoDeviceInput?.device {
                var error: NSError?

                do {
                    try device.lockForConfiguration()
                    if self.focusPointSupported {
                        device.focusMode = focusMode
                        device.focusPointOfInterest = point
                    }

                    if self.exposurePointSupported {
                        device.exposureMode = exposureMode
                        device.exposurePointOfInterest = point
                    }

                    device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                    device.unlockForConfiguration()
                } catch let error1 as NSError {
                    error = error1
                    print("Error in focusWithMode:exposeWithMode:atDevicePoint:monitorSubjectAreaChange: \(error?.description)")
                } catch {
                    fatalError()
                }

            }
        }
    }

    private func updateFocusIndicatorLayer() {
        if let device = videoDeviceInput?.device {
            if focusIndicatorLayer.hidden == false {
                if device.focusMode == .Locked && device.exposureMode == .Locked {
                    focusIndicatorLayer.borderColor = UIColor(white: 1, alpha: 0.5).CGColor
                }
            }
        }
    }

    @objc private func subjectAreaDidChange(notification: NSNotification) {
        dispatch_async(dispatch_get_main_queue()) {
            self.disableFocusLockAnimated(true)
        }
    }

    public func disableFocusLockAnimated(animated: Bool) {
        if focusIndicatorAnimating {
            return
        }

        focusIndicatorAnimating = true
        focusIndicatorFadeOutTimer?.invalidate()

        if focusPointSupported || exposurePointSupported {
            focusWithMode(.ContinuousAutoFocus, exposeWithMode: .ContinuousAutoExposure, atDevicePoint: CGPoint(x: 0.5, y: 0.5), monitorSubjectAreaChange: false)

            if animated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                focusIndicatorLayer.borderColor = UIColor.whiteColor().CGColor
                focusIndicatorLayer.frame.size = CGSize(width: kIndicatorSize * 2, height: kIndicatorSize * 2)
                focusIndicatorLayer.transform = CATransform3DIdentity
                focusIndicatorLayer.position = previewView.center

                CATransaction.commit()

                let resizeAnimation = CABasicAnimation(keyPath: "transform")
                resizeAnimation.duration = 0.25
                resizeAnimation.fromValue = NSValue(CATransform3D: CATransform3DMakeScale(1.5, 1.5, 1))
                resizeAnimation.delegate = AnimationDelegate(block: { finished in
                    if finished {
                        self.focusIndicatorFadeOutTimer = NSTimer.after(0.85) { [unowned self] in
                            self.focusIndicatorLayer.opacity = 0

                            let fadeAnimation = CABasicAnimation(keyPath: "opacity")
                            fadeAnimation.duration = 0.25
                            fadeAnimation.fromValue = 1
                            fadeAnimation.delegate = AnimationDelegate(block: { finished in
                                if finished {
                                    CATransaction.begin()
                                    CATransaction.setDisableActions(true)
                                    self.focusIndicatorLayer.hidden = true
                                    self.focusIndicatorLayer.opacity = 1
                                    self.focusIndicatorLayer.frame.size = CGSize(width: kIndicatorSize, height: kIndicatorSize)
                                    CATransaction.commit()
                                    self.focusIndicatorAnimating = false
                                }
                            })

                            self.focusIndicatorLayer.addAnimation(fadeAnimation, forKey: nil)
                        }
                    }
                })

                focusIndicatorLayer.addAnimation(resizeAnimation, forKey: nil)
            } else {
                focusIndicatorLayer.hidden = true
                focusIndicatorAnimating = false
            }
        } else {
            focusIndicatorLayer.hidden = true
            focusIndicatorAnimating = false
        }
    }

    // MARK: - Capture Session

    public func setup() {
        // For backwards compatibility
        setupWithInitialRecordingMode(.Photo)
    }

     /**
     Initializes the camera and has to be called before calling `startCamera()` / `stopCamera()`

     - parameter recordingMode: The supported recording modes.
     */
    public func setupWithInitialRecordingMode(recordingMode: RecordingMode) {
        if setupComplete {
            return
        }

        checkSDKVersion()
        checkDeviceAuthorizationStatus()

        guard let glContext = EAGLContext(API: .OpenGLES2) else {
            return
        }

        videoPreviewView = GLKView(frame: CGRectZero, context: glContext)
        videoPreviewView!.autoresizingMask = [.FlexibleWidth, .FlexibleHeight]
        videoPreviewView!.transform = CGAffineTransformMakeRotation(CGFloat(M_PI_2))
        videoPreviewView!.frame = previewView.bounds

        previewView.addSubview(videoPreviewView!)
        previewView.sendSubviewToBack(videoPreviewView!)

        var options = [String: AnyObject]()
        
        if let colorspace = CGColorSpaceCreateDeviceRGB() {
            options = [kCIContextWorkingColorSpace: colorspace]
        }
        ciContext = CIContext(EAGLContext: glContext, options: options)
        videoPreviewView!.bindDrawable()

        var preferredCameraPosition: AVCaptureDevicePosition = .Back
        if !allowedCameraPositions.contains(.Back) {
            preferredCameraPosition = .Front
        }

        setupWithPreferredCameraPosition(preferredCameraPosition) {
            if self.session.canSetSessionPreset(recordingMode.sessionPreset) {
                self.session.sessionPreset = recordingMode.sessionPreset
            }

            if let device = self.videoDeviceInput?.device {
                if device.isFlashModeSupported(self.allowedFlashModes[0]) {
                    self.flashMode = self.allowedFlashModes[0]
                } else {
                    self.flashMode = .Off
                }

                if device.isTorchModeSupported(self.allowedTorchModes[0]) {
                    self.torchMode = self.allowedTorchModes[0]
                } else {
                    self.torchMode = .Off
                }
            }

            self.delegate?.cameraControllerDidCompleteSetup?(self)
        }

        setupFocusIndicator()
        setupMaskLayers()

        setupComplete = true
    }

    public func switchToRecordingMode(recordingMode: RecordingMode) {
        switchToRecordingMode(recordingMode, animated: true)
    }

    public func switchToRecordingMode(recordingMode: RecordingMode, animated: Bool) {
        delegate?.cameraController?(self, willSwitchToRecordingMode: recordingMode)

        focusIndicatorLayer.hidden = true

        let sessionGroup = dispatch_group_create()

        if let videoPreviewView = videoPreviewView {
            let (snapshotWithBlur, snapshot) = addSnapshotViewsToVideoPreviewView(videoPreviewView)

            UIView.animateWithDuration(animated ? 0.4 : 0, delay: 0, options: .CurveEaseOut, animations: {
                // Transitioning between the regular snapshot and the blurred snapshot, this automatically removes `snapshot` and adds `snapshotWithBlur` to the view hierachy
                UIView.transitionFromView(snapshot, toView: snapshotWithBlur, duration: 0, options: .TransitionCrossDissolve, completion: nil)
                self.delegate?.cameraControllerAnimateAlongsideFirstPhaseOfRecordingModeSwitchBlock?(self)()
                }) { _ in
                    self.delegate?.cameraControllerFirstPhaseOfRecordingModeSwitchAnimationCompletionBlock?(self)()
                    // Wait for mode switch
                    dispatch_group_notify(sessionGroup, dispatch_get_main_queue()) {
                        // Giving the preview view a bit of time to redraw first
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64((animated ? 0.05 : 0) * Double(NSEC_PER_SEC))), dispatch_get_main_queue()) {
                            UIView.animateWithDuration(animated ? 0.2 : 0, animations: {
                                // Cross fading between blur and live preview, this sets `snapshotWithBlur.hidden` to `true` and `videoPreviewView.hidden` to false
                                UIView.transitionFromView(snapshotWithBlur, toView: videoPreviewView, duration: 0, options: [.TransitionCrossDissolve, .ShowHideTransitionViews], completion: nil)
                                self.delegate?.cameraControllerAnimateAlongsideSecondPhaseOfRecordingModeSwitchBlock?(self)()
                                }) { _ in
                                    // Deleting the blurred snapshot
                                    snapshotWithBlur.removeFromSuperview()
                            }
                        }
                    }
            }
        }

        dispatch_async(sessionQueue) {
            dispatch_group_enter(sessionGroup)
            if self.session.canSetSessionPreset(recordingMode.sessionPreset) {
                self.session.sessionPreset = recordingMode.sessionPreset
            }
            dispatch_group_leave(sessionGroup)

            /// Try to use the equivalent flash/torch mode when switchting recording
            /// modes. Select the next available mode if the equivalent is not allowed.
            switch recordingMode {
            case .Photo:
                if self.flashAvailable {
                    let translatedFlashMode = AVCaptureFlashMode(rawValue: self.torchMode.rawValue)!
                    if self.allowedFlashModes.contains(translatedFlashMode) {
                        self.flashMode = translatedFlashMode
                    } else {
                        self.selectNextFlashMode()
                    }

                    if self.torchAvailable {
                        self.torchMode = .Off
                    }
                }
            case .Video:
                if self.torchAvailable {
                    let translatedTorchMode = AVCaptureTorchMode(rawValue: self.flashMode.rawValue)!
                    if self.allowedTorchModes.contains(translatedTorchMode) {
                        self.torchMode = translatedTorchMode
                    } else {
                        self.selectNextTorchMode()
                    }

                    if self.flashAvailable {
                        self.flashMode = .Off
                    }
                }
            }

            self.delegate?.cameraController?(self, didSwitchToRecordingMode: recordingMode)
        }
    }

    private func setupWithPreferredCameraPosition(cameraPosition: AVCaptureDevicePosition, completion: (() -> (Void))?) {
        dispatch_async(sessionQueue) {
            self.setupVideoInputsForPreferredCameraPosition(cameraPosition)
            self.setupAudioInputs()
            self.setupOutputs()

            completion?()
        }
    }

    private func setupVideoInputsForPreferredCameraPosition(cameraPosition: AVCaptureDevicePosition) {
        var error: NSError?

        let videoDevice = CameraController.deviceWithMediaType(AVMediaTypeVideo, preferringPosition: cameraPosition)
        let videoDeviceInput: AVCaptureDeviceInput!
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch let error1 as NSError {
            error = error1
            videoDeviceInput = nil
        }

        if let error = error {
            print("Error in setupVideoInputsForPreferredCameraPosition: \(error.description)")
        }

        if self.session.canAddInput(videoDeviceInput) {
            self.session.addInput(videoDeviceInput)
            self.videoDeviceInput = videoDeviceInput

            dispatch_async(dispatch_get_main_queue()) {
                if let videoPreviewView = self.videoPreviewView, device = videoDevice {
                    if device.position == .Front {
                        // front camera is mirrored so we need to transform the preview view
                        videoPreviewView.transform = CGAffineTransformMakeRotation(CGFloat(M_PI_2))
                        videoPreviewView.transform = CGAffineTransformScale(videoPreviewView.transform, 1, -1)
                    } else {
                        videoPreviewView.transform = CGAffineTransformMakeRotation(CGFloat(M_PI_2))
                    }
                }
            }
        }
    }

    private func setupAudioInputs() {
        var error: NSError?

        let audioDevice = CameraController.deviceWithMediaType(AVMediaTypeAudio, preferringPosition: nil)
        let audioDeviceInput: AVCaptureDeviceInput!
        do {
            audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice)
        } catch let error1 as NSError {
            error = error1
            audioDeviceInput = nil
        }

        if let error = error {
            print("Error in setupAudioInputs: \(error.description)")
        }

        if self.session.canAddInput(audioDeviceInput) {
            self.session.addInput(audioDeviceInput)
            self.audioDeviceInput = audioDeviceInput
        }
    }

    private func setupOutputs() {
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
        if self.session.canAddOutput(videoDataOutput) {
            self.session.addOutput(videoDataOutput)
            self.videoDataOutput = videoDataOutput
        }

        if audioDeviceInput != nil {
            let audioDataOutput = AVCaptureAudioDataOutput()
            audioDataOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            if self.session.canAddOutput(audioDataOutput) {
                self.session.addOutput(audioDataOutput)
                self.audioDataOutput = audioDataOutput
            }
        }

        let stillImageOutput = AVCaptureStillImageOutput()
        if self.session.canAddOutput(stillImageOutput) {
            self.session.addOutput(stillImageOutput)
            self.stillImageOutput = stillImageOutput
        }
    }

    /**
    Starts the camera preview.
    */
    public func startCamera() {
        assert(setupComplete, "setup() needs to be called before calling startCamera()")

        if session.running {
            return
        }

        startCameraWithCompletion(nil)

        // Used to determine device orientation even if orientation lock is active
        motionManager.startAccelerometerUpdatesToQueue(motionManagerQueue, withHandler: { accelerometerData, _ in
            guard let accelerometerData = accelerometerData else {
                return
            }

            if abs(accelerometerData.acceleration.y) < abs(accelerometerData.acceleration.x) {
                if accelerometerData.acceleration.x > 0 {
                    self.captureVideoOrientation = .LandscapeLeft
                } else {
                    self.captureVideoOrientation = .LandscapeRight
                }
            } else {
                if accelerometerData.acceleration.y > 0 {
                    self.captureVideoOrientation = .PortraitUpsideDown
                } else {
                    self.captureVideoOrientation = .Portrait
                }
            }
        })
    }

    private func startCameraWithCompletion(completion: (() -> (Void))?) {
        dispatch_async(sessionQueue) {
            self.addObserver(self, forKeyPath: "sessionRunningAndDeviceAuthorized", options: [.Old, .New], context: &sessionRunningAndDeviceAuthorizedContext)
            self.addObserver(self, forKeyPath: "stillImageOutput.capturingStillImage", options: [.Old, .New], context: &capturingStillImageContext)

            self.addObserversToInputDevice()

            self.runtimeErrorHandlingObserver = NSNotificationCenter.defaultCenter().addObserverForName(AVCaptureSessionRuntimeErrorNotification, object: self.session, queue: nil, usingBlock: { [unowned self] _ in
                dispatch_async(self.sessionQueue) {
                    self.session.startRunning()
                }
                })

            self.session.startRunning()
            completion?()
        }
    }

    private func addObserversToInputDevice() {
        if let device = self.videoDeviceInput?.device {
            device.addObserver(self, forKeyPath: "focusMode", options: [.Old, .New], context: &focusAndExposureContext)
            device.addObserver(self, forKeyPath: "exposureMode", options: [.Old, .New], context: &focusAndExposureContext)
        }

        NSNotificationCenter.defaultCenter().addObserver(self, selector: "subjectAreaDidChange:", name: AVCaptureDeviceSubjectAreaDidChangeNotification, object: self.videoDeviceInput?.device)
    }

    private func removeObserversFromInputDevice() {
        if let device = self.videoDeviceInput?.device {
            device.removeObserver(self, forKeyPath: "focusMode", context: &focusAndExposureContext)
            device.removeObserver(self, forKeyPath: "exposureMode", context: &focusAndExposureContext)
        }

        NSNotificationCenter.defaultCenter().removeObserver(self, name: AVCaptureDeviceSubjectAreaDidChangeNotification, object: self.videoDeviceInput?.device)
    }

    /**
    Stops the camera preview.
    */
    public func stopCamera() {
        assert(setupComplete, "setup() needs to be called before calling stopCamera()")

        if !session.running {
            return
        }

        stopCameraWithCompletion(nil)
        motionManager.stopAccelerometerUpdates()
    }

    private func stopCameraWithCompletion(completion: (() -> (Void))?) {
        dispatch_async(sessionQueue) {
            self.session.stopRunning()

            self.removeObserversFromInputDevice()

            if let runtimeErrorHandlingObserver = self.runtimeErrorHandlingObserver {
                NSNotificationCenter.defaultCenter().removeObserver(runtimeErrorHandlingObserver)
            }

            self.removeObserver(self, forKeyPath: "sessionRunningAndDeviceAuthorized", context: &sessionRunningAndDeviceAuthorizedContext)
            self.removeObserver(self, forKeyPath: "stillImageOutput.capturingStillImage", context: &capturingStillImageContext)
            completion?()
        }
    }

    /// Check if the current device has a flash.
    public var flashAvailable: Bool {
        if let device = self.videoDeviceInput?.device {
            return device.flashAvailable
        }

        return false
    }

    /// Check if the current device has a torch.
    public var torchAvailable: Bool {
        if let device = self.videoDeviceInput?.device {
            return device.torchAvailable
        }

        return false
    }

    // MARK: - Still Image Capture

    public func squareTakenImage(image: UIImage) -> UIImage {
        let stack = FixedFilterStack()
        var scale = (image.size.width / image.size.height)
        if let captureVideoOrientation = self.captureVideoOrientation {
            if captureVideoOrientation == .LandscapeRight || captureVideoOrientation == .LandscapeLeft {
                scale = (image.size.height / image.size.width)
            }
        }
        let offset = (1.0 - scale) / 2.0
        stack.orientationCropFilter.cropRect = CGRect(x: offset, y: 0, width: scale, height: 1.0)
        return PhotoProcessor.processWithUIImage(image, filters: stack.activeFilters)!
    }

    /**
    Takes a photo and hands it over to the completion block.

    - parameter completion: A completion block that has an image and an error as parameters.
    If the image was taken sucessfully the error is nil.
    */
    public func takePhoto(completion: TakePhotoBlock) {
        if let stillImageOutput = self.stillImageOutput {
            dispatch_async(sessionQueue) {
                let connection = stillImageOutput.connectionWithMediaType(AVMediaTypeVideo)

                // Update the orientation on the still image output video connection before capturing.
                if let captureVideoOrientation = self.captureVideoOrientation {
                    connection.videoOrientation = captureVideoOrientation
                }

                stillImageOutput.captureStillImageAsynchronouslyFromConnection(connection) {
                    (imageDataSampleBuffer: CMSampleBuffer?, error: NSError?) -> Void in

                    if let imageDataSampleBuffer = imageDataSampleBuffer {
                        let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(imageDataSampleBuffer)
                        var image = UIImage(data: imageData)
                        if self.squareMode {
                            image = self.squareTakenImage(image!)
                        }
                        completion(image, nil)
                    } else {
                        completion(nil, error)
                    }
                }
            }
        }
    }

    // MARK: - Video Capture

    /**
    Starts recording a video.
    */
    public func startVideoRecording() {
        if assetWriter == nil {
            startWriting()
        }
    }

    /**
    Stop recording a video.
    */
    public func stopVideoRecording() {
        if assetWriter != nil {
            stopWriting()
        }
    }

    private func startWriting() {
        delegate?.cameraControllerDidStartRecording?(self)

        dispatch_async(sessionQueue) {
            var error: NSError?

            let outputFileURL = NSURL(fileURLWithPath: (NSTemporaryDirectory() as NSString).stringByAppendingPathComponent(kTempVideoFilename))
            do {
                try NSFileManager.defaultManager().removeItemAtURL(outputFileURL)
            } catch _ {
            }

            let newAssetWriter: AVAssetWriter!
            do {
                newAssetWriter = try AVAssetWriter(URL: outputFileURL, fileType: AVFileTypeQuickTimeMovie)
            } catch let error1 as NSError {
                error = error1
                newAssetWriter = nil
            } catch {
                fatalError()
            }

            if newAssetWriter == nil || error != nil {
                self.delegate?.cameraControllerDidFailRecording?(self, error: error)
                return
            }

            let videoCompressionSettings = self.videoDataOutput?.recommendedVideoSettingsForAssetWriterWithOutputFileType(AVFileTypeQuickTimeMovie)
            self.assetWriterVideoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: videoCompressionSettings as? [String: AnyObject])
            self.assetWriterVideoInput!.expectsMediaDataInRealTime = true

            var sourcePixelBufferAttributes: [String: AnyObject] = [String(kCVPixelBufferPixelFormatTypeKey): NSNumber(unsignedInt: kCVPixelFormatType_32BGRA), String(kCVPixelFormatOpenGLESCompatibility): kCFBooleanTrue]
            if let currentVideoDimensions = self.currentVideoDimensions {
                sourcePixelBufferAttributes[String(kCVPixelBufferWidthKey)] = NSNumber(int: currentVideoDimensions.width)
                sourcePixelBufferAttributes[String(kCVPixelBufferHeightKey)] = NSNumber(int: currentVideoDimensions.height)
            }

            self.assetWriterInputPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: self.assetWriterVideoInput!, sourcePixelBufferAttributes: sourcePixelBufferAttributes)

            if let videoDevice = self.videoDeviceInput?.device, captureVideoOrientation = self.captureVideoOrientation {
                if videoDevice.position == .Front {
                    self.assetWriterVideoInput?.transform = GetTransformForDeviceOrientation(captureVideoOrientation, mirrored: true)
                } else {
                    self.assetWriterVideoInput?.transform = GetTransformForDeviceOrientation(captureVideoOrientation)
                }
            }

            let canAddInput = newAssetWriter.canAddInput(self.assetWriterVideoInput!)
            if !canAddInput {
                self.assetWriterAudioInput = nil
                self.assetWriterVideoInput = nil
                self.delegate?.cameraControllerDidFailRecording?(self, error: nil)
                return
            }

            newAssetWriter.addInput(self.assetWriterVideoInput!)

            if self.audioDeviceInput != nil {
                let audioCompressionSettings = self.audioDataOutput?.recommendedAudioSettingsForAssetWriterWithOutputFileType(AVFileTypeQuickTimeMovie) as? [String: AnyObject]

                if newAssetWriter.canApplyOutputSettings(audioCompressionSettings, forMediaType: AVMediaTypeAudio) {
                    self.assetWriterAudioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioCompressionSettings)
                    self.assetWriterAudioInput?.expectsMediaDataInRealTime = true

                    if newAssetWriter.canAddInput(self.assetWriterAudioInput!) {
                        newAssetWriter.addInput(self.assetWriterAudioInput!)
                    }
                }
            }

            if UIDevice.currentDevice().multitaskingSupported {
                self.backgroundRecordingID = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler({})
            }

            self.videoWritingStarted = false
            self.assetWriter = newAssetWriter
            self.startTimeUpdateTimer()
        }
    }

    private func abortWriting() {
        if let assetWriter = assetWriter {
            assetWriter.cancelWriting()
            assetWriterAudioInput = nil
            assetWriterVideoInput = nil
            videoWritingStartTime = nil
            currentVideoTime = nil
            self.assetWriter = nil
            stopTimeUpdateTimer()

            // Remove temporary file
            let fileURL = assetWriter.outputURL
            do {
                try NSFileManager.defaultManager().removeItemAtURL(fileURL)
            } catch _ {
            }

            // End background task
            if let backgroundRecordingID = backgroundRecordingID where UIDevice.currentDevice().multitaskingSupported {
                UIApplication.sharedApplication().endBackgroundTask(backgroundRecordingID)
            }

            self.delegate?.cameraControllerDidFailRecording?(self, error: nil)
        }
    }

    private func stopWriting() {
        if let assetWriter = assetWriter {
            assetWriterAudioInput = nil
            assetWriterVideoInput = nil
            videoWritingStartTime = nil
            currentVideoTime = nil
            assetWriterInputPixelBufferAdaptor = nil
            self.assetWriter = nil

            dispatch_async(sessionQueue) {
                let fileURL = assetWriter.outputURL

                if assetWriter.status == .Unknown {
                    self.delegate?.cameraControllerDidFailRecording?(self, error: nil)
                    return
                }

                assetWriter.finishWritingWithCompletionHandler {
                    self.stopTimeUpdateTimer()

                    if assetWriter.status == .Failed {
                        dispatch_async(dispatch_get_main_queue()) {
                            if let backgroundRecordingID = self.backgroundRecordingID {
                                UIApplication.sharedApplication().endBackgroundTask(backgroundRecordingID)
                            }
                        }

                        self.delegate?.cameraControllerDidFailRecording?(self, error: nil)
                    } else if assetWriter.status == .Completed {
                        dispatch_async(dispatch_get_main_queue()) {
                            if let backgroundRecordingID = self.backgroundRecordingID {
                                UIApplication.sharedApplication().endBackgroundTask(backgroundRecordingID)
                            }
                        }

                        self.delegate?.cameraControllerDidFinishRecording?(self, fileURL: fileURL)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    func startTimeUpdateTimer() {
        dispatch_async(dispatch_get_main_queue()) {
            if let timeUpdateTimer = self.timeUpdateTimer {
                timeUpdateTimer.invalidate()
            }

            self.timeUpdateTimer = NSTimer.after(0.25, repeats: true, { () -> () in
                if let currentVideoTime = self.currentVideoTime, videoWritingStartTime = self.videoWritingStartTime {
                    let diff = CMTimeSubtract(currentVideoTime, videoWritingStartTime)
                    let seconds = Int(CMTimeGetSeconds(diff))

                    self.delegate?.cameraController?(self, recordedSeconds: seconds)

                    if let maximumVideoLength = self.maximumVideoLength where seconds >= maximumVideoLength {
                        self.stopVideoRecording()
                    }
                }
            })
        }
    }

    func stopTimeUpdateTimer() {
        dispatch_async(dispatch_get_main_queue()) {
            self.timeUpdateTimer?.invalidate()
            self.timeUpdateTimer = nil
        }
    }

    func addSnapshotViewsToVideoPreviewView(videoPreviewView: UIView) -> (snapshotWithBlur: UIView, snapshotWithoutBlur: UIView) {
        // Hiding live preview
        videoPreviewView.hidden = true

        // Adding a simple snapshot and immediately showing it
        let snapshot = videoPreviewView.snapshotViewAfterScreenUpdates(false)
        snapshot.transform = videoPreviewView.transform
        snapshot.frame = previewView.frame
        previewView.superview?.addSubview(snapshot)

        // Creating a snapshot with a UIBlurEffect added
        let snapshotWithBlur = videoPreviewView.snapshotViewAfterScreenUpdates(false)
        snapshotWithBlur.transform = videoPreviewView.transform
        snapshotWithBlur.frame = previewView.frame

        let visualEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .Dark))
        visualEffectView.frame = snapshotWithBlur.bounds
        visualEffectView.autoresizingMask = [.FlexibleWidth, .FlexibleHeight]
        snapshotWithBlur.addSubview(visualEffectView)

        return (snapshotWithBlur: snapshotWithBlur, snapshotWithoutBlur: snapshot)
    }

    class func deviceWithMediaType(mediaType: String, preferringPosition position: AVCaptureDevicePosition?) -> AVCaptureDevice? {
        // swiftlint:disable force_cast
        let devices = AVCaptureDevice.devicesWithMediaType(mediaType) as! [AVCaptureDevice]
        // swiftlint:enable force_cast
        var captureDevice = devices.first

        if let position = position {
            for device in devices {
                if device.position == position {
                    captureDevice = device
                    break
                }
            }
        }

        return captureDevice
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)

        if mediaType == CMMediaType(kCMMediaType_Audio) {
            self.currentAudioSampleBufferFormatDescription = formatDescription
            if let assetWriterAudioInput = self.assetWriterAudioInput where assetWriterAudioInput.readyForMoreMediaData {
                let success = assetWriterAudioInput.appendSampleBuffer(sampleBuffer)
                if !success {
                    self.abortWriting()
                }
            }

            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        currentVideoDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        let sourceImage: CIImage
        if #available(iOS 9.0, *) {
            sourceImage = CIImage(CVImageBuffer: imageBuffer)
        } else {
            sourceImage = CIImage(CVPixelBuffer: imageBuffer as CVPixelBuffer)
        }

        let filteredImage: CIImage?

        if effectFilter is NoneFilter {
            filteredImage = sourceImage
        } else {
            filteredImage = PhotoProcessor.processWithCIImage(sourceImage, filters: [effectFilter])
        }

        let sourceExtent = sourceImage.extent

        if let videoPreviewView = videoPreviewView {
            let targetRect = CGRect(x: 0, y: 0, width: videoPreviewView.drawableWidth, height: videoPreviewView.drawableHeight)

            videoPreviewFrame = sourceExtent
            videoPreviewFrame.fittedIntoTargetRect(targetRect, withContentMode: previewContentMode)
            updateSquareIndicatorView(self.videoPreviewFrame)
            if glContext != EAGLContext.currentContext() {
                EAGLContext.setCurrentContext(glContext)
            }

            videoPreviewView.bindDrawable()

            glClearColor(0, 0, 0, 1.0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

            currentVideoTime = timestamp

            if let assetWriter = assetWriter {
                if !videoWritingStarted {
                    videoWritingStarted = true

                    let success = assetWriter.startWriting()
                    if !success {
                        abortWriting()
                        return
                    }

                    assetWriter.startSessionAtSourceTime(timestamp)
                    videoWritingStartTime = timestamp
                }

                if let assetWriterInputPixelBufferAdaptor = assetWriterInputPixelBufferAdaptor, pixelBufferPool = assetWriterInputPixelBufferAdaptor.pixelBufferPool {
                    var renderedOutputPixelBuffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &renderedOutputPixelBuffer)
                    if status != 0 {
                        abortWriting()
                        return
                    }

                    if let filteredImage = filteredImage, renderedOutputPixelBuffer = renderedOutputPixelBuffer {
                        ciContext?.render(filteredImage, toCVPixelBuffer: renderedOutputPixelBuffer)
                        let drawImage = CIImage(CVPixelBuffer: renderedOutputPixelBuffer)
                        ciContext?.drawImage(drawImage, inRect: videoPreviewFrame, fromRect: sourceExtent)

                        if let assetWriterVideoInput = assetWriterVideoInput where assetWriterVideoInput.readyForMoreMediaData {
                            assetWriterInputPixelBufferAdaptor.appendPixelBuffer(renderedOutputPixelBuffer, withPresentationTime: timestamp)
                        }
                    }
                }
            } else {
                if let filteredImage = filteredImage {
                    ciContext?.drawImage(filteredImage, inRect: videoPreviewFrame, fromRect: sourceExtent)
                }
            }

            videoPreviewView.display()
        }
    }
}

extension CGRect {
    mutating func fittedIntoTargetRect(targetRect: CGRect, withContentMode contentMode: UIViewContentMode) {
        if !(contentMode == .ScaleAspectFit || contentMode == .ScaleAspectFill) {
            // Not implemented
            return
        }

        var scale = targetRect.width / self.width

        if contentMode == .ScaleAspectFit {
            if self.height * scale > targetRect.height {
                scale = targetRect.height / self.height
            }
        } else if contentMode == .ScaleAspectFill {
            if self.height * scale < targetRect.height {
                scale = targetRect.height / self.height
            }
        }

        let scaledWidth = self.width * scale
        let scaledHeight = self.height * scale
        let scaledX = targetRect.width / 2 - scaledWidth / 2
        let scaledY = targetRect.height / 2 - scaledHeight / 2

        self.origin.x = scaledX
        self.origin.y = scaledY
        self.size.width = scaledWidth
        self.size.height = scaledHeight
    }
}

// MARK: - Helper Functions

private func GetTransformForDeviceOrientation(orientation: AVCaptureVideoOrientation, mirrored: Bool = false) -> CGAffineTransform {
    let result: CGAffineTransform

    switch orientation {
    case .Portrait:
        result = CGAffineTransformMakeRotation(CGFloat(M_PI_2))
    case .PortraitUpsideDown:
        result = CGAffineTransformMakeRotation(CGFloat(3 * M_PI_2))
    case .LandscapeRight:
        result = mirrored ? CGAffineTransformMakeRotation(CGFloat(M_PI)) : CGAffineTransformIdentity
    case .LandscapeLeft:
        result = mirrored ? CGAffineTransformIdentity : CGAffineTransformMakeRotation(CGFloat(M_PI))
    }

    return result
}
