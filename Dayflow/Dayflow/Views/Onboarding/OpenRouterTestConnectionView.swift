//
//  OpenRouterTestConnectionView.swift
//  Dayflow
//
//  Test connection view for OpenRouter API
//

import SwiftUI

struct OpenRouterTestConnectionView: View {
    let apiKey: String
    let model: String
    let onTestComplete: (Bool) -> Void

    @State private var isLoading = false
    @State private var testResult: TestResult?
    @State private var hasSucceeded = false

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    private let successAccentColor = Color(red: 0.34, green: 1, blue: 0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Testing OpenRouter Connection")
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.9))

                Text("Model: \(modelDisplayName)")
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(.black.opacity(0.6))
            }

            // Test button
            DayflowSurfaceButton(
                action: runTest,
                content: {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if hasSucceeded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14))
                        }

                        Text(buttonText)
                            .font(.custom("Nunito", size: 14))
                            .fontWeight(.semibold)
                    }
                },
                background: hasSucceeded ? successAccentColor.opacity(0.2) : accentColor,
                foreground: hasSucceeded ? .black : .white,
                borderColor: hasSucceeded ? successAccentColor.opacity(0.3) : .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: !hasSucceeded
            )
            .disabled(isLoading || apiKey.isEmpty)
            .opacity((isLoading || apiKey.isEmpty) ? 0.6 : 1.0)

            // Result message
            if let result = testResult {
                VStack(alignment: .leading, spacing: 8) {
                    if result.success {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(successAccentColor)
                            Text("Success! Your OpenRouter API key is working.")
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(.black.opacity(0.7))
                        }

                        if let balance = result.balance {
                            Text("Account balance: $\(String(format: "%.2f", balance))")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.black.opacity(0.6))
                        }
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Color(hex: "E91515"))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Connection failed")
                                    .font(.custom("Nunito", size: 14))
                                    .fontWeight(.medium)
                                    .foregroundColor(Color(hex: "E91515"))

                                if let error = result.errorMessage {
                                    Text(error)
                                        .font(.custom("Nunito", size: 13))
                                        .foregroundColor(.black.opacity(0.6))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
    }

    private var modelDisplayName: String {
        switch model {
        case "openai/gpt-4o-mini": return "GPT-4o Mini"
        case "openai/gpt-4o": return "GPT-4o"
        case "anthropic/claude-3-5-sonnet": return "Claude 3.5 Sonnet"
        case "anthropic/claude-3-haiku": return "Claude 3 Haiku"
        case "google/gemini-pro-1.5": return "Gemini Pro 1.5"
        case "google/gemini-flash-1.5": return "Gemini Flash 1.5"
        default: return model
        }
    }

    private var buttonText: String {
        if isLoading {
            return "Testing..."
        } else if hasSucceeded {
            return "Test Successful!"
        } else {
            return "Test Connection"
        }
    }

    private func runTest() {
        guard !apiKey.isEmpty else { return }

        isLoading = true
        testResult = nil
        hasSucceeded = false

        Task {
            // Test the OpenRouter API
            let result = await testOpenRouterConnection(apiKey: apiKey, model: model)

            await MainActor.run {
                self.testResult = result
                self.hasSucceeded = result.success
                self.isLoading = false
                self.onTestComplete(result.success)
            }
        }
    }

    private func testOpenRouterConnection(apiKey: String, model: String) async -> TestResult {
        // Create a simple test request
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Dayflow/1.0", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Dayflow Test", forHTTPHeaderField: "X-Title")

        // Simple test message
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Say 'Hello from Dayflow!' in exactly 4 words."]
            ],
            "max_tokens": 20,
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return TestResult(success: false, errorMessage: "Invalid response", balance: nil)
            }

            if httpResponse.statusCode == 200 {
                // Success - try to parse response
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Check if it's a valid chat completion response
                        if let choices = json["choices"] as? [[String: Any]],
                           !choices.isEmpty,
                           let firstChoice = choices.first,
                           let message = firstChoice["message"] as? [String: Any],
                           let _ = message["content"] {
                            // Valid response structure
                            return TestResult(success: true, errorMessage: nil, balance: nil)
                        } else {
                            // Log the unexpected structure for debugging
                            print("[OpenRouter Test] Unexpected response structure: \(json)")
                            return TestResult(
                                success: false,
                                errorMessage: "Unexpected response format from OpenRouter. The API connection works but the response format is incompatible.",
                                balance: nil
                            )
                        }
                    }
                } catch {
                    print("[OpenRouter Test] Failed to parse response: \(String(data: data, encoding: .utf8) ?? "nil")")
                    return TestResult(
                        success: false,
                        errorMessage: "Failed to parse response: \(error.localizedDescription)",
                        balance: nil
                    )
                }

                // If we get here but didn't return, something went wrong
                return TestResult(
                    success: false,
                    errorMessage: "Unexpected response format",
                    balance: nil
                )
            } else {
                // Try to parse error message
                var errorMessage = "HTTP error \(httpResponse.statusCode)"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    errorMessage = message
                }

                // Common error messages
                if httpResponse.statusCode == 401 {
                    errorMessage = "Invalid API key. Please check your OpenRouter API key."
                } else if httpResponse.statusCode == 402 {
                    errorMessage = "Insufficient credits. Please add credits to your OpenRouter account."
                } else if httpResponse.statusCode == 429 {
                    errorMessage = "Rate limited. Please wait a moment and try again."
                }

                return TestResult(success: false, errorMessage: errorMessage, balance: nil)
            }
        } catch {
            return TestResult(
                success: false,
                errorMessage: "Network error: \(error.localizedDescription)",
                balance: nil
            )
        }
    }

    private struct TestResult {
        let success: Bool
        let errorMessage: String?
        let balance: Double?
    }
}

struct OpenRouterTestConnectionView_Previews: PreviewProvider {
    static var previews: some View {
        OpenRouterTestConnectionView(
            apiKey: "",
            model: "openai/gpt-4o-mini",
            onTestComplete: { _ in }
        )
        .padding()
    }
}