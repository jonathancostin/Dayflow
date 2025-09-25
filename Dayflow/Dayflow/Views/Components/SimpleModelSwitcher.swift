//
//  SimpleModelSwitcher.swift
//  Dayflow
//
//  Simplified model switcher for OpenRouter to avoid compilation issues
//

import SwiftUI

struct SimpleModelSwitcher: View {
    @Binding var isPresented: Bool
    let onComplete: () -> Void

    @State private var selectedModel: String = UserDefaults.standard.string(forKey: "openRouterModel") ?? "openai/gpt-4o-mini"
    @State private var isCustom = false
    @State private var customPath = ""

    private let predefinedModels = [
        ("GPT-4o Mini (Recommended)", "openai/gpt-4o-mini"),
        ("GPT-4o", "openai/gpt-4o"),
        ("Claude 3.5 Sonnet", "anthropic/claude-3-5-sonnet"),
        ("Claude 3 Haiku", "anthropic/claude-3-haiku"),
        ("Gemini Pro 1.5", "google/gemini-pro-1.5"),
        ("Gemini Flash 1.5", "google/gemini-flash-1.5")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelSelection

                    if isCustom {
                        customModelInput
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            footer
        }
        .background(Color.white)
        .onAppear {
            checkIfCustomModel()
        }
    }

    private var header: some View {
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
    }

    private var modelSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Model:")
                .font(.custom("Nunito", size: 14))
                .fontWeight(.medium)
                .foregroundColor(.black.opacity(0.8))

            ForEach(predefinedModels, id: \.1) { name, path in
                modelOption(name: name, path: path)
            }

            // Custom option
            HStack(spacing: 8) {
                Button(action: {
                    isCustom = true
                    selectedModel = "custom"
                }) {
                    HStack {
                        Image(systemName: isCustom ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundColor(isCustom ? .blue : .black.opacity(0.3))

                        Text("Custom Model...")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.8))

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    private func modelOption(name: String, path: String) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                selectedModel = path
                isCustom = false
                customPath = ""
            }) {
                HStack {
                    Image(systemName: selectedModel == path && !isCustom ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(selectedModel == path && !isCustom ? .blue : .black.opacity(0.3))

                    Text(name)
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.8))

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private var customModelInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter OpenRouter model path:")
                .font(.custom("Nunito", size: 13))
                .foregroundColor(.black.opacity(0.6))

            TextField("e.g. google/gemini-2.0-flash-thinking-exp", text: $customPath)
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

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                isPresented = false
            }
            .buttonStyle(.plain)
            .font(.custom("Nunito", size: 14))
            .foregroundColor(.black.opacity(0.6))
            .pointingHandCursor()

            Spacer()

            Button(action: saveModel) {
                Text("Use This Model")
                    .font(.custom("Nunito", size: 14))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(canSave ? Color.blue : Color.gray.opacity(0.3))
                    )
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .pointingHandCursor()
        }
        .padding(20)
    }

    private var canSave: Bool {
        if isCustom {
            return !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !selectedModel.isEmpty && selectedModel != "custom"
    }

    private func checkIfCustomModel() {
        let current = UserDefaults.standard.string(forKey: "openRouterModel") ?? "openai/gpt-4o-mini"

        if !predefinedModels.contains(where: { $0.1 == current }) {
            isCustom = true
            customPath = current
            selectedModel = "custom"
        } else {
            selectedModel = current
            isCustom = false
        }
    }

    private func saveModel() {
        let modelToSave = isCustom ? customPath.trimmingCharacters(in: .whitespacesAndNewlines) : selectedModel

        guard !modelToSave.isEmpty else { return }

        // Save the new model
        UserDefaults.standard.set(modelToSave, forKey: "openRouterModel")

        // Update the provider type
        let type = LLMProviderType.openRouter(model: modelToSave)
        if let encoded = try? JSONEncoder().encode(type) {
            UserDefaults.standard.set(encoded, forKey: "llmProviderType")
        }

        // Reinitialize the service
        Task {
            await LLMService.shared.reinitialize()
        }

        onComplete()
        isPresented = false
    }
}