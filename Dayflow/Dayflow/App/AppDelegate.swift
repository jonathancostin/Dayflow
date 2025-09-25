//
//  AppDelegate.swift
//  Dayflow
//
//  Created by Jerry Liu on 4/26/25.
//

import AppKit
import ServiceManagement
import ScreenCaptureKit
import PostHog
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // Controls whether the app is allowed to terminate.
    // Default is false so Cmd+Q/Dock/App menu quit will be cancelled
    // and the app will continue running in the background.
    static var allowTermination: Bool = false
    private var statusBar: StatusBarController!
    private var recorder : ScreenRecorder!
    private var analyticsSub: AnyCancellable?
    private var powerObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Block termination by default; only specific flows enable it.
        AppDelegate.allowTermination = false
        // Configure analytics (prod only; default opt-in ON)
        let info = Bundle.main.infoDictionary
        let POSTHOG_API_KEY = info?["PHPostHogApiKey"] as? String ?? ""
        let POSTHOG_HOST = info?["PHPostHogHost"] as? String ?? "https://us.i.posthog.com"
        if !POSTHOG_API_KEY.isEmpty {
            AnalyticsService.shared.start(apiKey: POSTHOG_API_KEY, host: POSTHOG_HOST)
        }

        // App opened (cold start)
        AnalyticsService.shared.capture("app_opened", ["cold_start": true])

        // App updated check
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let lastBuild = UserDefaults.standard.string(forKey: "lastRunBuild")
        if let last = lastBuild, last != build {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            AnalyticsService.shared.capture("app_updated", ["from_version": last, "to_version": "\(version) (\(build))"])        
        }
        UserDefaults.standard.set(build, forKey: "lastRunBuild")
        
        statusBar = StatusBarController()   // safe: AppKit is ready, main thread
        
        // Check if we've passed the screen recording permission step
        let onboardingStep = UserDefaults.standard.integer(forKey: "onboardingStep")
        let didOnboard = UserDefaults.standard.bool(forKey: "didOnboard")
        
        // Seed recording flag low, then create recorder so the first
        // transition to true will reliably start capture.
        AppState.shared.isRecording = false
        recorder = ScreenRecorder(autoStart: true)
        
        // Only attempt to start recording if we're past the screen step or fully onboarded
        // Steps: 0=welcome, 1=howItWorks, 2=screen, 3=llmSelection, 4=llmSetup, 5=done
        if didOnboard || onboardingStep > 2 {
            // Try to start recording, but handle permission failures gracefully
            Task {
                do {
                    // Check if we have permission by trying to access content
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    // Permission granted, start recording
                    await MainActor.run {
                        AppState.shared.isRecording = true
                    }
                    AnalyticsService.shared.capture("recording_toggled", ["enabled": true, "reason": "auto"]) 
                } catch {
                    // No permission or error - don't start recording
                    // User will need to grant permission in onboarding
                    await MainActor.run {
                        AppState.shared.isRecording = false
                    }
                    print("Screen recording permission not granted, skipping auto-start")
                }
            }
        } else {
            // Still in early onboarding, don't attempt recording
            AppState.shared.isRecording = false
        }
        
        // Register login item helper (Ventura+). Non-fatal if user disabled it.
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.loginItem(identifier: "teleportlabs.com.Dayflow.LoginItem").register()
            } catch {
                print("Login item register failed: \(error)")
            }
        }
        
        // Start the Gemini analysis background job
        setupGeminiAnalysis()

        // Start inactivity monitoring for idle reset
        InactivityMonitor.shared.start()

        // Observe recording state
        analyticsSub = AppState.shared.$isRecording
            .removeDuplicates()
            .sink { enabled in
                AnalyticsService.shared.capture("recording_toggled", ["enabled": enabled, "reason": "user"]) 
                AnalyticsService.shared.setPersonProperties(["recording_enabled": enabled])
            }

        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppDelegate.allowTermination = true
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowTermination {
            return .terminateNow
        }
        // Soft-quit: hide windows and remove Dock icon, but keep status item + background tasks
        NSApp.hide(nil)
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }
    
    // Start Gemini analysis as a background task
    private func setupGeminiAnalysis() {
        // Perform after a short delay to ensure other initialization completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AnalysisManager.shared.startAnalysisJob()
            print("AppDelegate: Gemini analysis job started")
            AnalyticsService.shared.capture("analysis_job_started", [
                "provider": {
                    if let data = UserDefaults.standard.data(forKey: "llmProviderType"),
                       let providerType = try? JSONDecoder().decode(LLMProviderType.self, from: data) {
                        switch providerType {
                        case .geminiDirect: return "gemini"
                        case .dayflowBackend: return "dayflow"
                        case .ollamaLocal: return "ollama"
                        case .openRouter: return "openrouter"
                        }
                    }
                    return "unknown"
                }()
            ])
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = powerObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            powerObserver = nil
        }
        // If onboarding not completed, mark abandoned with last step
        let didOnboard = UserDefaults.standard.bool(forKey: "didOnboard")
        if !didOnboard {
            let stepIdx = UserDefaults.standard.integer(forKey: "onboardingStep")
            let stepName: String = {
                switch stepIdx { case 0: return "welcome"; case 1: return "how_it_works"; case 2: return "screen_recording"; case 3: return "llm_selection"; case 4: return "llm_setup"; default: return "unknown" }
            }()
            AnalyticsService.shared.capture("onboarding_abandoned", ["last_step": stepName])
        }
        AnalyticsService.shared.capture("app_terminated")
    }
}
