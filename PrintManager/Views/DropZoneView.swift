//
//  DropZoneView.swift
//  PrintManager
//
//  Enhanced drop zone with modern animations and visual feedback
//

import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false
    @State private var dropAnimation = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.05),
                        Color.accentColor.opacity(0.1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                // Animated border
                if isTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            AngularGradient(
                                colors: [.accentColor, .accentColor.opacity(0.3), .accentColor],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .scaleEffect(dropAnimation ? 1.02 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: dropAnimation
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                        )
                        .foregroundColor(.secondary.opacity(0.3))
                }
                
                // Content
                VStack(spacing: 16) {
                    // Icon with bounce animation
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.to.line")
                        .font(.system(size: isTargeted ? 48 : 42))
                        .foregroundColor(isTargeted ? .accentColor : .secondary)
                        .scaleEffect(isTargeted ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTargeted)
                        .modifier(BounceSymbolModifier(value: isTargeted))
                    
                    // Text
                    VStack(spacing: 4) {
                        Text(isTargeted ? "Release to Add Files" : "Drop Files Here")
                            .font(.headline)
                            .foregroundColor(isTargeted ? .accentColor : .primary)
                        
                        Text("PDF, Images, Office Documents")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .animation(.easeInOut, value: isTargeted)
                    
                    // Or divider with button
                    HStack {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(height: 1)
                        
                        Text("or")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 8)
                    
                    // Browse button
                    Button(action: {
                        appState.showingFilePicker = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                            Text("Browse Files")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(40)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
            .modifier(DropZoneOnChangeModifier(value: isTargeted, action: { newValue in
                dropAnimation = newValue
            }))
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var droppedURLs: [URL] = []
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }
                
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    droppedURLs.append(url)
                }
            }
        }
        
        group.notify(queue: .main) {
            if !droppedURLs.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    appState.addFiles(urls: droppedURLs)
                    
                    // Select newly added files
                    let newFiles = appState.files.suffix(droppedURLs.count)
                    appState.selectedFiles = Set(newFiles.map { $0.id })
                }
                
                // Visual feedback - flash effect
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationManager.shared.sendNotification(
                        title: "Files Added",
                        body: "\(droppedURLs.count) file(s) added to queue"
                    )
                }
            }
        }
        
        return true
    }
}

// MARK: - Animated Progress View

struct AnimatedProgressView: View {
    let progress: Double
    let message: String
    
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Background circle
                Circle()
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 6)
                    .frame(width: 80, height: 80)
                
                // Progress circle
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress)
                
                // Percentage
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
        )
    }
}

// MARK: - File Animation View (for drag animations)

struct FileDropAnimation: View {
    let count: Int
    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 1
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<min(count, 5), id: \.self) { index in
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.accentColor)
                    Text("Processing file \(index + 1)")
                        .font(.subheadline)
                }
                .offset(x: offset + CGFloat(index * 10))
                .opacity(opacity - Double(index) * 0.2)
            }
        }
    }
}

// MARK: - Status Banner View

struct StatusBanner: View {
    let message: String
    let type: BannerType
    let isPresented: Bool
    
    enum BannerType {
        case success, warning, error, info
        
        var color: Color {
            switch self {
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            case .info: return .accentColor
            }
        }
        
        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }
    
    var body: some View {
        if isPresented {
            HStack(spacing: 10) {
                Image(systemName: type.icon)
                    .font(.title3)
                
                Text(message)
                    .font(.subheadline)
                    .lineLimit(2)
                
                Spacer()
            }
            .padding()
            .background(type.color.opacity(0.15))
            .foregroundColor(type.color)
            .cornerRadius(10)
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let icon: String
    let title: String
    let subtitle: String?
    let color: Color
    let action: () -> Void
    
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        color: Color = .accentColor,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(color)
                }
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 70)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack {
                        Image(systemName: "plus")
                        Text(actionTitle)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Compatibility Modifiers

private struct BounceSymbolModifier: ViewModifier {
    let value: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.bounce, value: value)
        } else {
            content
        }
    }
}

private struct DropZoneOnChangeModifier: ViewModifier {
    let value: Bool
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value, initial: false) { _, newValue in
                action(newValue)
            }
        } else {
            content.onChange(of: value) { newValue in
                action(newValue)
            }
        }
    }
}
