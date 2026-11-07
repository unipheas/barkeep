import SwiftUI

@MainActor
struct StatusStreamView: View {
    @Environment(AppState.self) private var state
    @State private var model = StatusStreamModel()
    @State private var saveError: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Live Device Status").font(.title2.bold())
            Text(state.host).font(.caption).foregroundStyle(.secondary)
            Text("Receive live device updates. Each packet shows changed fields; encoded image and timer data are included as Base64. The Device tab shows the screen preview.")
                .font(.callout)
            HStack {
                if model.running {
                    Button("Stop Stream") { model.stop() }
                } else {
                    Button("Start Stream") { model.start(client:state.client) }.buttonStyle(.borderedProminent)
                }
                Text("\(model.packetCount) packets").font(.caption).monospacedDigit()
                Spacer()
                Button("Save Latest Packet…") { save() }.disabled(model.latestData == nil)
            }
            if let error = model.error ?? saveError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.latestJSON.isEmpty {
                Text(model.latestJSON).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(10).background(.quaternary)
            }
        }
        .onDisappear { model.stop() }
        .onChange(of:state.host) { _,_ in model.stop() }
        .onChange(of:state.token) { _,_ in model.stop() }
    }
    private func save() {
        guard let data = model.latestData else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "busy-bar-status.json"
        panel.begin {
            guard $0 == .OK, let url = panel.url else { return }
            do { try data.write(to:url,options:.atomic); saveError = nil }
            catch { saveError = error.localizedDescription }
        }
    }
}
