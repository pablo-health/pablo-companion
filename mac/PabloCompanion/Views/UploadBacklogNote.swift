import SwiftUI

/// Tells the clinician that session audio is still on this Mac, waiting to
/// upload, and lets them send it now instead of waiting for the next retry.
struct UploadBacklogNote: View {
    let backlog: UploadBacklog
    let isUploading: Bool
    let onUploadNow: () -> Void

    var body: some View {
        if let message = backlog.message {
            HStack(spacing: 10) {
                Image(systemName: backlog.hasFailed ? "exclamationmark.icloud.fill" : "icloud.and.arrow.up")
                    .font(.title3)
                    .foregroundStyle(backlog.hasFailed ? Color.pabloError : Color.pabloHoney)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownDeep)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isUploading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Uploading")
                } else {
                    Button("Upload Now", action: onUploadNow)
                        .accessibilityLabel("Upload session audio now")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((backlog.hasFailed ? Color.pabloError : Color.pabloHoney).opacity(0.1))
            )
            .accessibilityElement(children: .contain)
        }
    }
}

#Preview("Failed") {
    UploadBacklogNote(backlog: UploadBacklog(waiting: 2, hasFailed: true), isUploading: false, onUploadNow: {})
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}

#Preview("Uploading") {
    UploadBacklogNote(backlog: UploadBacklog(waiting: 1), isUploading: true, onUploadNow: {})
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}
