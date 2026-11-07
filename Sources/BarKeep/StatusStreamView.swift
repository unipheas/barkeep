import SwiftUI

@MainActor
struct StatusStreamView: View {
    #if DEBUG
    internal var didAppear: ((Self) -> Void)?
    #endif
    @Environment(AppState.self) private var state
    @State private var model: StatusStreamModel
    @State private var saveError: String?
    private let exportFile: FileExport.Handler
    init(model: StatusStreamModel? = nil, exportFile: @escaping FileExport.Handler = FileExport.present) {
        self.exportFile = exportFile
        _model = State(initialValue: model ?? StatusStreamModel())
    }

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
        #if DEBUG
        .onAppear { didAppear?(self) }
        #endif
        .onDisappear { model.stop() }
        .onChange(of:state.host) { _,_ in model.stop() }
        .onChange(of:state.token) { _,_ in model.stop() }
    }
    private func save() {
        guard let data = model.latestData else { return }
        exportFile(data, "busy-bar-status.json") { result in
            switch result {
            case .success: saveError = nil
            case .failure(let error): saveError = error.localizedDescription
            }
        }
    }
}
