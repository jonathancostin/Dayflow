//
//  OpenRouterModelSwitcherView.swift
//  Dayflow
//
//  Quick model switcher for OpenRouter provider
//

import SwiftUI

struct OpenRouterModelSwitcherView: View {
    @Binding var isPresented: Bool
    let onModelSelected: (String) -> Void

    @State private var selectedModel: String = ""
    @State private var showCustomInput = false
    @State private var customModelPath = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?

    init(isPresented: Binding<Bool>, onModelSelected: @escaping (String) -> Void) {
        self._isPresented = isPresented
        self.onModelSelected = onModelSelected

        // Load current model
        let currentModel = UserDefaults.standard.string(forKey: "openRouterModel") ?? "openai/gpt-4o-mini"
        self._selectedModel = State(initialValue: currentModel)

        // Check if it's a custom model
        let knownModels = ["openai/gpt-4o-mini", "openai/gpt-4o", "anthropic/claude-3-5-sonnet",
                          "anthropic/claude-3-haiku", "google/gemini-pro-1.5", "google/gemini-flash-1.5"]
        if !knownModels.contains(currentModel) {
            self._showCustomInput = State(initialValue: true)
            self._customModelPath = State(initialValue: currentModel)
            self._selectedModel = State(initialValue: "custom")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Switch OpenRouter Model")
                    .font(.custom("Nunito", size: 18))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.9))

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(.black.opacity(0.5))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(20)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 20) {
                // Model picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Model:")
                        .font(.custom("Nunito", size: 14))
                        .fontWeight(.medium)
                        .foregroundColor(.black.opacity(0.8))

                    Picker("", selection: $selectedModel) {
                        Text("GPT-4o Mini (Recommended)").tag("openai/gpt-4o-mini")
                        Text("GPT-4o").tag("openai/gpt-4o")
                        Text("Claude 3.5 Sonnet").tag("anthropic/claude-3-5-sonnet")
                        Text("Claude 3 Haiku").tag("anthropic/claude-3-haiku")
                        Text("Gemini Pro 1.5").tag("google/gemini-pro-1.5")
                        Text("Gemini Flash 1.5").tag("google/gemini-flash-1.5")
                        Text("Custom Model...").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .onChange(of: selectedModel) { _, newValue in
                        showCustomInput = (newValue == "custom")
                        if newValue != "custom" {
                            customModelPath = ""
                        }
                        testResult = nil
                    }
                }

                // Custom model input
                if showCustomInput {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter OpenRouter model path:")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.6))

                        TextField("e.g. google/gemini-2.0-flash-thinking-exp", text: $customModelPath)
                            .font(.custom("Nunito", size: 14))
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.black.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
                            )

                        Text("Make sure the model supports vision/image inputs")
                            .font(.custom("Nunito", size: 11))
                            .foregroundColor(.black.opacity(0.5))
                    }
                }

                // Test button
                Button(action: testModel) {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12))
                        }
                        Text(isTesting ? "Testing..." : "Test Model")
                            .font(.custom("Nunito", size: 14))
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.9))
                    )
                    .foregroundColor(.white)
                    .disabled(isTesting || (showCustomInput && customModelPath.isEmpty))
                    .opacity((isTesting || (showCustomInput && customModelPath.isEmpty)) ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                // Test result
                if let result = testResult {
                    HStack(spacing: 8) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.success ? .green : .red)
                            .font(.system(size: 14))

                        Text(result.message)
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.7))
                    }
                    .padding(.vertical, 8)
                }

                Spacer()
            }
            .padding(20)

            Divider()

            // Footer buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.6))
                .pointingHandCursor()

                Spacer()

                Button("Use This Model") {
                    let modelToUse = showCustomInput && !customModelPath.isEmpty ? customModelPath : selectedModel
                    onModelSelected(modelToUse)
                }
                .buttonStyle(.plain)
                .font(.custom("Nunito", size: 14))
                .fontWeight(.semibold)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue)
                )
                .foregroundColor(.white)
                .disabled(showCustomInput && customModelPath.isEmpty)
                .opacity((showCustomInput && customModelPath.isEmpty) ? 0.6 : 1)
                .pointingHandCursor()
            }
            .padding(20)
        }
        .background(Color.white)
    }

    private func testModel() {
        guard let apiKey = KeychainManager.shared.retrieve(for: "openrouter") else {
            testResult = TestResult(success: false, message: "No API key found")
            return
        }

        let modelToTest = showCustomInput && !customModelPath.isEmpty ? customModelPath : selectedModel

        isTesting = true
        testResult = nil

        Task {
            // Simple test request
            let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("Dayflow/1.0", forHTTPHeaderField: "HTTP-Referer")

            let requestBody: [String: Any] = [
                "model": modelToTest,
                "messages": [
                    ["role": "user", "content": "Reply with exactly: OK"]
                ],
                "max_tokens": 10
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                let (_, response) = try await URLSession.shared.data(for: request)

                await MainActor.run {
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            testResult = TestResult(success: true, message: "Model is working!")
                        } else {
                            testResult = TestResult(success: false, message: "Error \(httpResponse.statusCode)")
                        }
                    }
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = TestResult(success: false, message: "Connection failed")
                    isTesting = false
                }
            }
        }
    }

    private struct TestResult {
        let success: Bool
        let message: String
    }
}