//
//  OpenRouterProvider.swift
//  Dayflow
//

import Foundation
import AVFoundation
import AppKit
import CoreImage

final class OpenRouterProvider: LLMProvider {
    private let apiKey: String
    private let endpoint: String
    private let model: String
    private let frameExtractionInterval: TimeInterval = 60.0 // Extract frame every 60 seconds

    // Vision-capable models on OpenRouter
    private static let supportedModels = [
        "openai/gpt-4o",
        "openai/gpt-4o-mini",
        "anthropic/claude-3-5-sonnet",
        "anthropic/claude-3-opus",
        "anthropic/claude-3-haiku",
        "google/gemini-pro-1.5",
        "google/gemini-flash-1.5"
    ]

    init(apiKey: String, endpoint: String = "https://openrouter.ai/api/v1", model: String = "openai/gpt-4o-mini") {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
    }

    func transcribeVideo(videoData: Data, mimeType: String, prompt: String, batchStartTime: Date, videoDuration: TimeInterval, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        let callStart = Date()

        // Save video to temporary file for processing
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try videoData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Extract frames at intervals
        let frames = try await extractFrames(from: tempURL)

        print("[OpenRouter] Extracted \(frames.count) frames from video")

        guard !frames.isEmpty else {
            throw NSError(domain: "OpenRouterProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "No frames could be extracted from video"])
        }

        // Get descriptions for each frame
        var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []

        for (index, frame) in frames.enumerated() {
            print("[OpenRouter] Describing frame \(index + 1)/\(frames.count) at \(frame.timestamp)s")
            if let description = await describeFrame(frame, batchId: batchId) {
                frameDescriptions.append((timestamp: frame.timestamp, description: description))
                print("[OpenRouter] Frame \(index + 1) described successfully")
            } else {
                print("[OpenRouter] Failed to describe frame \(index + 1)")
            }
        }

        print("[OpenRouter] Successfully described \(frameDescriptions.count) out of \(frames.count) frames")

        // Merge frame descriptions into coherent observations
        let observations = try await mergeFrameDescriptions(
            frameDescriptions,
            batchStartTime: batchStartTime,
            videoDuration: videoDuration,
            batchId: batchId
        )

        let totalTime = Date().timeIntervalSince(callStart)
        let log = LLMCall(
            timestamp: callStart,
            latency: totalTime,
            input: "OpenRouter processing: \(frames.count) frames → \(observations.count) observations",
            output: "Extracted \(frames.count) frames, merged into \(observations.count) observations in \(String(format: "%.2f", totalTime))s"
        )

        return (observations, log)
    }

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        let callStart = Date()

        let sortedObservations = context.batchObservations.sorted { $0.startTs < $1.startTs }

        // Generate activity cards from observations
        let cards = try await generateCardsFromObservations(
            observations: sortedObservations,
            existingCards: context.existingCards,
            categories: context.categories,
            batchId: batchId
        )

        let totalLatency = Date().timeIntervalSince(callStart)
        let log = LLMCall(
            timestamp: callStart,
            latency: totalLatency,
            input: "OpenRouter activity card generation",
            output: "Generated \(cards.count) activity cards in \(String(format: "%.2f", totalLatency))s"
        )

        return (cards, log)
    }

    // MARK: - Frame Extraction

    private struct FrameData {
        let image: Data  // JPEG data
        let timestamp: TimeInterval  // Seconds from video start
    }

    private func extractFrames(from videoURL: URL) async throws -> [FrameData] {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds > 0 else {
            throw NSError(domain: "OpenRouterProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid video duration"])
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true

        var frames: [FrameData] = []
        var currentTime: TimeInterval = 0

        while currentTime < durationSeconds {
            let cmTime = CMTime(seconds: currentTime, preferredTimescale: 600)

            do {
                let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)

                // Downscale and convert to JPEG
                if let scaledImage = downscaleImage(cgImage: cgImage, scale: 0.5) {
                    if let imageData = cgImageToJPEGData(scaledImage, quality: 0.85) {
                        frames.append(FrameData(image: imageData, timestamp: currentTime))
                        print("[OpenRouter] Extracted frame at \(currentTime)s, size: \(imageData.count) bytes")
                    } else {
                        print("[OpenRouter] Failed to convert frame to JPEG at \(currentTime)s")
                    }
                } else {
                    print("[OpenRouter] Failed to downscale frame at \(currentTime)s")
                }
            } catch {
                print("[OpenRouter] Warning: Failed to extract frame at \(currentTime)s: \(error)")
            }

            currentTime += frameExtractionInterval
        }

        return frames
    }

    private func downscaleImage(cgImage: CGImage, scale: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let outputImage = filter.outputImage else { return nil }

        let context = CIContext(options: [.highQualityDownsample: true])
        return context.createCGImage(outputImage, from: outputImage.extent)
    }

    private func cgImageToJPEGData(_ cgImage: CGImage, quality: CGFloat) -> Data? {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmapRep.representation(using: .jpeg, properties: [
            NSBitmapImageRep.PropertyKey.compressionFactor: quality
        ])
    }

    private func compressImage(_ imageData: Data, targetSize: Int) -> Data? {
        guard let nsImage = NSImage(data: imageData) else { return nil }

        // Try different compression levels
        let qualities: [CGFloat] = [0.7, 0.5, 0.3, 0.1]

        for quality in qualities {
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData) else {
                continue
            }

            if let compressed = bitmapRep.representation(using: .jpeg, properties: [
                NSBitmapImageRep.PropertyKey.compressionFactor: quality
            ]) {
                if compressed.count <= targetSize {
                    return compressed
                }
            }
        }

        // If still too large, also reduce dimensions
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        if let scaledImage = downscaleImage(cgImage: cgImage, scale: 0.5) {
            return cgImageToJPEGData(scaledImage, quality: 0.5)
        }

        return nil
    }

    // MARK: - OpenRouter API

    private struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int?
        let stream: Bool
    }

    private struct ChatMessage: Codable {
        let role: String
        let content: ChatContent
    }

    private enum ChatContent: Codable {
        case text(String)
        case multipart([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text):
                try container.encode(text)
            case .multipart(let parts):
                try container.encode(parts)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else if let parts = try? container.decode([ContentPart].self) {
                self = .multipart(parts)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid content type")
            }
        }
    }

    private struct ContentPart: Codable {
        let type: String
        let text: String?
        let image_url: ImageURL?

        struct ImageURL: Codable {
            let url: String
        }
    }

    private struct ChatResponse: Codable {
        let id: String
        let model: String
        let choices: [Choice]

        struct Choice: Codable {
            let message: ResponseMessage
            let finish_reason: String?
        }

        struct ResponseMessage: Codable {
            let role: String
            let content: String
        }
    }

    private func callOpenRouterAPI(_ request: ChatRequest, operation: String, batchId: Int64?, maxRetries: Int = 3) async throws -> ChatResponse {
        let url = URL(string: "\(endpoint)/chat/completions")!
        let callGroupId = UUID().uuidString
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                urlRequest.setValue("Dayflow/1.0", forHTTPHeaderField: "HTTP-Referer")
                urlRequest.setValue("Dayflow AI-powered timeline", forHTTPHeaderField: "X-Title")
                urlRequest.httpBody = try JSONEncoder().encode(request)
                urlRequest.timeoutInterval = 60.0

                let apiStart = Date()

                // Create logging context
                let ctx = LLMCallContext(
                    batchId: batchId,
                    callGroupId: callGroupId,
                    attempt: attempt + 1,
                    provider: "openrouter",
                    model: request.model,
                    operation: operation,
                    requestMethod: urlRequest.httpMethod,
                    requestURL: urlRequest.url,
                    requestHeaders: urlRequest.allHTTPHeaderFields,
                    requestBody: operation == "describe_frame" ? nil : urlRequest.httpBody,
                    startedAt: apiStart
                )

                let (data, response) = try await URLSession.shared.data(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "OpenRouterProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                }

                let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
                    if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
                        acc[k] = v.description
                    }
                }

                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"

                    LLMLogger.logFailure(
                        ctx: ctx,
                        http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data),
                        finishedAt: Date(),
                        errorDomain: "OpenRouterProvider",
                        errorCode: httpResponse.statusCode,
                        errorMessage: errorBody
                    )

                    // Handle rate limiting
                    if httpResponse.statusCode == 429 {
                        if attempt < maxRetries - 1 {
                            let backoffDelay = pow(2.0, Double(attempt)) * 2.0
                            try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                            continue
                        }
                    }

                    throw NSError(domain: "OpenRouterProvider", code: httpResponse.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "OpenRouter API error (\(httpResponse.statusCode)): \(errorBody)"
                    ])
                }

                do {
                    let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)

                    LLMLogger.logSuccess(
                        ctx: ctx,
                        http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders as [String: String], responseBody: data),
                        finishedAt: Date()
                    )

                    return chatResponse
                } catch {
                    // Log the raw response for debugging
                    print("[OpenRouter] Failed to decode response. Raw data: \(String(data: data, encoding: .utf8) ?? "nil")")
                    print("[OpenRouter] Decode error: \(error)")

                    // Try to extract error message if it's an error response
                    if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMessage = errorDict["error"] as? [String: Any],
                       let message = errorMessage["message"] as? String {
                        throw NSError(domain: "OpenRouterProvider", code: 11, userInfo: [
                            NSLocalizedDescriptionKey: "OpenRouter API error: \(message)"
                        ])
                    }

                    throw error
                }

            } catch {
                lastError = error
                print("[OpenRouter] Request failed (attempt \(attempt + 1)/\(maxRetries)): \(error)")

                if attempt < maxRetries - 1 {
                    let backoffDelay = pow(2.0, Double(attempt)) * 2.0
                    try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? NSError(domain: "OpenRouterProvider", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Request failed after \(maxRetries) attempts"
        ])
    }

    // MARK: - Frame Description

    private func describeFrame(_ frame: FrameData, batchId: Int64?) async -> String? {
        // Check image size and compress if needed
        let imageData: Data
        if frame.image.count > 1_000_000 { // If larger than 1MB, compress further
            if let compressedData = compressImage(frame.image, targetSize: 800_000) {
                imageData = compressedData
            } else {
                imageData = frame.image
            }
        } else {
            imageData = frame.image
        }

        let base64String = imageData.base64EncodedString()

        let content = ChatContent.multipart([
            ContentPart(type: "text", text: """
                Describe what you see on this computer screen in 1-2 sentences.
                Focus on: what application is open, what the user is doing, and any relevant details visible.
                Be specific and factual.
                """, image_url: nil),
            ContentPart(type: "image_url", text: nil, image_url: ContentPart.ImageURL(url: "data:image/jpeg;base64,\(base64String)"))
        ])

        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "user", content: content)
            ],
            temperature: 0.3,
            max_tokens: 150,
            stream: false
        )

        do {
            let response = try await callOpenRouterAPI(request, operation: "describe_frame", batchId: batchId, maxRetries: 2)
            if let content = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) {
                print("[OpenRouter] Frame description received: \(content.prefix(100))...")
                return content
            } else {
                print("[OpenRouter] Empty response for frame at \(frame.timestamp)s")
                return nil
            }
        } catch {
            print("[OpenRouter] Failed to describe frame at \(frame.timestamp)s: \(error)")
            if let nsError = error as NSError? {
                print("[OpenRouter] Error details - Domain: \(nsError.domain), Code: \(nsError.code)")
                print("[OpenRouter] Error info: \(nsError.userInfo)")
            }
            return nil
        }
    }

    // MARK: - Observation Merging

    private func mergeFrameDescriptions(_ frameDescriptions: [(timestamp: TimeInterval, description: String)],
                                      batchStartTime: Date,
                                      videoDuration: TimeInterval,
                                      batchId: Int64?) async throws -> [Observation] {

        guard !frameDescriptions.isEmpty else {
            // Check if this is a custom model
            let isCustomModel = !["openai/gpt-4o-mini", "openai/gpt-4o", "anthropic/claude-3-5-sonnet",
                                 "anthropic/claude-3-haiku", "google/gemini-pro-1.5",
                                 "google/gemini-flash-1.5"].contains(model)

            let errorMessage = isCustomModel ?
                "Failed to process images. The model '\(model)' likely doesn't support vision/image inputs. Please use a vision-capable model." :
                "No frame descriptions could be generated. Please check your API key and try again."

            throw NSError(domain: "OpenRouterProvider", code: 4, userInfo: [
                NSLocalizedDescriptionKey: errorMessage
            ])
        }

        // Format descriptions for the prompt
        var formattedDescriptions = ""
        for frame in frameDescriptions {
            let minutes = Int(frame.timestamp) / 60
            let seconds = Int(frame.timestamp) % 60
            let timeStr = String(format: "%02d:%02d", minutes, seconds)
            formattedDescriptions += "[\(timeStr)] \(frame.description)\n"
        }

        let durationMinutes = Int(videoDuration / 60)
        let durationSeconds = Int(videoDuration.truncatingRemainder(dividingBy: 60))
        let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)

        let prompt = """
        You have \(frameDescriptions.count) snapshots from a \(durationString) screen recording.

        Group these snapshots into 2-5 coherent activity segments that explain what happened during this time.

        Snapshots:
        \(formattedDescriptions)

        Return a JSON array of segments:
        [
          {
            "startTimestamp": "MM:SS",
            "endTimestamp": "MM:SS",
            "description": "Natural language summary of what happened"
          }
        ]

        Requirements:
        - Create 2-5 segments
        - Timestamps must be within 00:00 and \(durationString)
        - Cover at least 80% of the video duration
        - Merge brief interruptions into surrounding activities
        """

        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: .text("You are a helpful assistant that analyzes screen recordings and returns valid JSON.")),
                ChatMessage(role: "user", content: .text(prompt))
            ],
            temperature: 0.5,
            max_tokens: 1000,
            stream: false
        )

        let response = try await callOpenRouterAPI(request, operation: "merge_observations", batchId: batchId)

        guard let content = response.choices.first?.message.content else {
            throw NSError(domain: "OpenRouterProvider", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response from OpenRouter"])
        }

        // Parse the JSON response using the robust extractor
        let segments = try extractJSON(from: content, type: [VideoSegment].self)

        // Convert segments to observations
        var observations: [Observation] = []
        for segment in segments {
            let startSeconds = TimeInterval(parseVideoTimestamp(segment.startTimestamp))
            let endSeconds = TimeInterval(parseVideoTimestamp(segment.endTimestamp))

            let startDate = batchStartTime.addingTimeInterval(startSeconds)
            let endDate = batchStartTime.addingTimeInterval(endSeconds)

            observations.append(
                Observation(
                    id: nil,
                    batchId: 0,
                    startTs: Int(startDate.timeIntervalSince1970),
                    endTs: Int(endDate.timeIntervalSince1970),
                    observation: segment.description,
                    metadata: nil,
                    llmModel: model,
                    createdAt: Date()
                )
            )
        }

        return observations
    }

    private struct VideoSegment: Codable {
        let startTimestamp: String
        let endTimestamp: String
        let description: String
    }

    private func parseSegments(from data: Data) throws -> [VideoSegment] {
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenRouterProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response"])
        }
        return try extractJSON(from: responseString, type: [VideoSegment].self)
    }

    // MARK: - Activity Card Generation

    private func generateCardsFromObservations(observations: [Observation],
                                              existingCards: [ActivityCardData],
                                              categories: [LLMCategoryDescriptor],
                                              batchId: Int64?) async throws -> [ActivityCardData] {

        guard !observations.isEmpty else {
            return existingCards
        }

        // Format observations for the prompt
        let observationLines = observations.map { obs in
            let startTime = formatTimestampForPrompt(obs.startTs)
            let endTime = formatTimestampForPrompt(obs.endTs)
            return "[\(startTime) - \(endTime)]: \(obs.observation)"
        }.joined(separator: "\n")

        // Format categories
        let categoryList = categories.isEmpty ? ["Work", "Personal", "Communication", "Entertainment", "Learning"] : categories.map { $0.name }
        let categoriesText = categoryList.map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        Analyze these computer activities and create an activity card:

        Activities:
        \(observationLines)

        Categories to choose from:
        \(categoriesText)

        Create a JSON object with:
        {
          "title": "5-8 word conversational title",
          "summary": "2-3 sentence summary in first person without using 'I'",
          "category": "Choose from the categories above"
        }

        Guidelines:
        - Title should be casual and specific
        - Summary should start with action verbs
        - Include specific app names and details
        - Natural, conversational tone
        """

        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: .text("You are a helpful assistant that analyzes computer activity and returns valid JSON.")),
                ChatMessage(role: "user", content: .text(prompt))
            ],
            temperature: 0.7,
            max_tokens: 500,
            stream: false
        )

        let response = try await callOpenRouterAPI(request, operation: "generate_activity_card", batchId: batchId)

        guard let content = response.choices.first?.message.content else {
            throw NSError(domain: "OpenRouterProvider", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid response for activity card"])
        }

        struct CardResponse: Codable {
            let title: String
            let summary: String
            let category: String
        }

        let cardResponse = try extractJSON(from: content, type: CardResponse.self)

        // Create the activity card
        let card = ActivityCardData(
            startTime: formatTimestampForPrompt(observations.first!.startTs),
            endTime: formatTimestampForPrompt(observations.last!.endTs),
            category: normalizeCategory(cardResponse.category, categories: categories),
            subcategory: "",
            title: cardResponse.title,
            summary: cardResponse.summary,
            detailedSummary: "",
            distractions: nil,
            appSites: nil
        )

        // Check if we should merge with the last existing card
        var allCards = existingCards
        if let lastCard = allCards.last {
            let shouldMerge = try await checkShouldMerge(lastCard: lastCard, newCard: card, batchId: batchId)
            if shouldMerge {
                let mergedCard = try await mergeTwoCards(lastCard: lastCard, newCard: card, batchId: batchId)
                allCards[allCards.count - 1] = mergedCard
            } else {
                allCards.append(card)
            }
        } else {
            allCards.append(card)
        }

        return allCards
    }

    private func checkShouldMerge(lastCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?) async throws -> Bool {
        let prompt = """
        Should these two consecutive activities be merged into one card?

        Previous: \(lastCard.title) (\(lastCard.startTime) - \(lastCard.endTime))
        Summary: \(lastCard.summary)

        New: \(newCard.title) (\(newCard.startTime) - \(newCard.endTime))
        Summary: \(newCard.summary)

        Return JSON: {"merge": true/false, "reason": "brief explanation"}

        Only merge if they're the same activity continuing. Be strict - when in doubt, keep separate.
        """

        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "user", content: .text(prompt))
            ],
            temperature: 0.3,
            max_tokens: 200,
            stream: false
        )

        let response = try await callOpenRouterAPI(request, operation: "check_merge", batchId: batchId)

        guard let content = response.choices.first?.message.content else {
            return false
        }

        struct MergeDecision: Codable {
            let merge: Bool
            let reason: String
        }

        let decision = try? extractJSON(from: content, type: MergeDecision.self)
        return decision?.merge ?? false
    }

    private func mergeTwoCards(lastCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?) async throws -> ActivityCardData {
        let prompt = """
        Merge these two activities into a single card:

        Activity 1 (\(lastCard.startTime) - \(lastCard.endTime)):
        \(lastCard.title) - \(lastCard.summary)

        Activity 2 (\(newCard.startTime) - \(newCard.endTime)):
        \(newCard.title) - \(newCard.summary)

        Return JSON: {"title": "merged title", "summary": "merged summary"}

        Create a unified title and summary covering \(lastCard.startTime) to \(newCard.endTime).
        """

        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "user", content: .text(prompt))
            ],
            temperature: 0.5,
            max_tokens: 300,
            stream: false
        )

        let response = try await callOpenRouterAPI(request, operation: "merge_cards", batchId: batchId)

        guard let content = response.choices.first?.message.content else {
            throw NSError(domain: "OpenRouterProvider", code: 9, userInfo: [NSLocalizedDescriptionKey: "Failed to merge cards"])
        }

        struct MergedContent: Codable {
            let title: String
            let summary: String
        }

        let merged = try extractJSON(from: content, type: MergedContent.self)

        return ActivityCardData(
            startTime: lastCard.startTime,
            endTime: newCard.endTime,
            category: lastCard.category,
            subcategory: lastCard.subcategory,
            title: merged.title,
            summary: merged.summary,
            detailedSummary: "",
            distractions: nil,
            appSites: nil
        )
    }

    // MARK: - Helpers

    private func extractJSON<T: Decodable>(from text: String, type: T.Type) throws -> T {
        // Try direct decoding first
        if let data = text.data(using: .utf8) {
            if let result = try? JSONDecoder().decode(type, from: data) {
                return result
            }
        }

        // Clean the text and try to extract JSON
        var cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        let patterns = [
            "```json\\n(.*?)```",
            "```JSON\\n(.*?)```",
            "```\\n(.*?)```"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let range = NSRange(location: 0, length: cleanedText.count)
                if let match = regex.firstMatch(in: cleanedText, options: [], range: range) {
                    if let jsonRange = Range(match.range(at: 1), in: cleanedText) {
                        cleanedText = String(cleanedText[jsonRange])
                        break
                    }
                }
            }
        }

        // Try to find JSON object or array in the text
        if let startIndex = cleanedText.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let endIndex = cleanedText.lastIndex(where: { $0 == "}" || $0 == "]" }) {
            let jsonSubstring = cleanedText[startIndex...endIndex]
            if let jsonData = jsonSubstring.data(using: .utf8) {
                do {
                    return try JSONDecoder().decode(type, from: jsonData)
                } catch {
                    print("[OpenRouter] JSON decode error: \(error)")
                    print("[OpenRouter] Attempted to parse: \(jsonSubstring)")
                }
            }
        }

        throw NSError(domain: "OpenRouterProvider", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "Could not extract valid JSON from response",
            "response": text
        ])
    }

    private func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return categories.first?.name ?? "Work" }

        let normalized = cleaned.lowercased()
        if let match = categories.first(where: { $0.name.lowercased() == normalized }) {
            return match.name
        }

        return categories.first?.name ?? cleaned
    }

    private func formatTimestampForPrompt(_ unixTime: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}