//
//  NotificationManager.swift
//  PrintManager
//
//  Handles macOS user notifications for completed operations
//

import Foundation
import UserNotifications
import AppKit

@MainActor
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    @Published var isAuthorized = false
    
    private let notificationsEnabledKey = "notificationsEnabled"
    
    private var isNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsEnabledKey) as? Bool ?? true
    }
    
    private init() {
        requestAuthorization()
    }
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.isAuthorized = granted
                if let error = error {
                    print("Notification authorization error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func sendNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        sound: UNNotificationSound = .default,
        actionIdentifier: String? = nil
    ) {
        // Check if notifications are enabled in settings
        guard isNotificationsEnabled else {
            print("Notifications disabled in settings")
            return
        }
        
        guard isAuthorized else {
            print("Notifications not authorized")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }
    
    // Convenience methods for common notifications
    
    func notifyConversionComplete(fileCount: Int, successCount: Int) {
        let title = "Conversion Complete"
        let body: String
        if successCount == fileCount {
            body = "Successfully converted \(successCount) file(s)"
        } else {
            body = "Converted \(successCount) of \(fileCount) files"
        }
        sendNotification(title: title, body: body)
    }
    
    func notifyPrintComplete(fileCount: Int, printerName: String) {
        let title = "Print Complete"
        let body = "\(fileCount) file(s) sent to \(printerName)"
        sendNotification(title: title, body: body)
    }
    
    func notifyCompressionComplete(originalSize: Int64, compressedSize: Int64) {
        let savings = Double(originalSize - compressedSize) / Double(originalSize) * 100
        let title = "Compression Complete"
        let body = "Saved \(Int(savings))% (\(ByteCountFormatter.string(fromByteCount: compressedSize, countStyle: .file)))"
        sendNotification(title: title, body: body)
    }
    
    func notifyError(title: String, message: String) {
        sendNotification(title: title, body: message, sound: .defaultCritical)
    }
}
