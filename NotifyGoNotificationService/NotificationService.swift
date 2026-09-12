import UserNotifications
import UIKit
import ImageIO

final class NotificationService: UNNotificationServiceExtension, URLSessionDownloadDelegate {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var session: URLSession?
    private let lock = NSLock()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); handler = nil; return
        }
        self.content = content
        let metadata = (content.userInfo["notifygo"] as? [String: Any]) ?? [:]
        attach(sourceImage(metadata: metadata), to: content)
        guard let text = metadata["imageURL"] as? String, let url = URL(string: text),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { finish(); return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        lock.lock()
        let callback = handler
        handler = nil
        let value = content
        lock.unlock()
        session?.invalidateAndCancel()
        if let callback, let value { callback(value) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 2_000_000 || totalBytesExpectedToWrite > 2_000_000 { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
           ["image/png", "image/jpeg"].contains(response.mimeType ?? ""),
           let attributes = try? FileManager.default.attributesOfItem(atPath: location.path),
           let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000,
           let source = CGImageSourceCreateWithURL(location as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 512,
               kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary) {
            lock.lock()
            if handler != nil, let content { attach(UIImage(cgImage: thumbnail), to: content) }
            lock.unlock()
        }
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish() }
    }

    private func attach(_ image: UIImage?, to content: UNMutableNotificationContent) {
        guard let data = image?.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try data.write(to: url)
            content.attachments = [try UNNotificationAttachment(identifier: "source", url: url)]
        } catch { /* Preserve the original notification if an attachment cannot be created. */ }
    }

    private func sourceImage(metadata: [String: Any]) -> UIImage {
        let colors: [String: UIColor] = ["blue": .systemBlue, "indigo": .systemIndigo, "purple": .systemPurple, "pink": .systemPink, "orange": .systemOrange, "green": .systemGreen]
        let color = colors[(metadata["color"] as? String) ?? ""] ?? .systemBlue
        return UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            if let emoji = metadata["emoji"] as? String, !emoji.isEmpty {
                (String(emoji.prefix(2)) as NSString).draw(in: CGRect(x: 22, y: 22, width: 100, height: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 64)])
            } else {
                let symbol = UIImage(systemName: (metadata["symbol"] as? String) ?? "bell.badge.fill") ?? UIImage(systemName: "bell.badge.fill")
                symbol?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 32, y: 32, width: 64, height: 64))
            }
        }
    }
}
