import SwiftUI
import Network

@main struct DobiApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor final class Lamp: ObservableObject {
    @AppStorage("lampIP") var ip = ""
    @Published var power = false
    @Published var brightness = 50.0
    @Published var temperature = 2700.0
    @Published var hue = 0.0
    @Published var saturation = 100.0
    @Published var message = ""
    private let queue = DispatchQueue(label: "dobi.network")

    func send(_ method: String, _ params: [Any], completion: (([String]) -> Void)? = nil) {
        guard !ip.isEmpty else { message = "Enter the lamp IP address in Settings."; return }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: 55443, using: .tcp)
        guard let encoded = try? JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params]) else { return }
        var payload = encoded
        payload.append(contentsOf: [13, 10])
        let lock = NSLock()
        var done = false
        func finish(_ result: Result<Data, Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            lock.unlock()
            connection.cancel()
            Task { @MainActor in
                switch result {
                case .failure(let error): self.message = error.localizedDescription
                case .success(let bytes):
                    do {
                        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
                        if let error = object["error"] { self.message = String(describing: error); return }
                        self.message = ""
                        completion?((object["result"] as? [Any] ?? []).map { String(describing: $0) })
                    } catch { self.message = error.localizedDescription }
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error = error { finish(.failure(error)); return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, error in
                        if let error = error { finish(.failure(error)); return }
                        guard let bytes = bytes, let line = bytes.split(separator: 10).first else {
                            finish(.failure(NSError(domain: "Dobi", code: 1, userInfo: [NSLocalizedDescriptionKey: "No response from lamp"]))); return
                        }
                        finish(.success(Data(line)))
                    }
                })
            case .failed(let error): Task { @MainActor in finish(.failure(error)) }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { Task { @MainActor in
            finish(.failure(NSError(domain: "Dobi", code: 2, userInfo: [NSLocalizedDescriptionKey: "Connection timed out"])))
        } }
    }
    func refresh() {
        send("get_prop", ["power", "bright", "ct", "hue", "sat"]) { values in
            guard values.count >= 5 else { return }
            self.power = values[0] == "on"
            self.brightness = Double(values[1]) ?? self.brightness
            self.temperature = Double(values[2]) ?? self.temperature
            self.hue = Double(values[3]) ?? self.hue
            self.saturation = Double(values[4]) ?? self.saturation
        }
    }
}

struct ContentView: View {
    @StateObject private var lamp = Lamp()
    @State private var colorMode = false
    @State private var showingSettings = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Button {
                        lamp.send("set_power", [lamp.power ? "off" : "on", "smooth", 500]) { _ in lamp.refresh() }
                    } label: {
                        Label(lamp.power ? "Turn off" : "Turn on", systemImage: "power")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.card()
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Brightness  |  \(Int(lamp.brightness))%").font(.headline)
                        Slider(value: $lamp.brightness, in: 1...100, step: 1, onEditingChanged: { editing in
                            if !editing { lamp.send("set_bright", [Int(lamp.brightness), "smooth", 300]) { _ in lamp.refresh() } }
                        }).tint(.yellow)
                    }.card()
                    VStack(alignment: .leading, spacing: 20) {
                        Text(colorMode ? "Color" : "Color temperature  |  \(Int(lamp.temperature)) K").font(.headline)
                        Picker("Mode", selection: $colorMode) {
                            Text("Color temperature").tag(false)
                            Text("Color").tag(true)
                        }.pickerStyle(.segmented).onChange(of: colorMode) { mode in
                            if mode { lamp.send("set_hsv", [Int(lamp.hue), Int(lamp.saturation), "smooth", 300]) }
                            else { lamp.send("set_ct_abx", [Int(lamp.temperature), "smooth", 300]) }
                        }
                        if colorMode {
                            Text("Hue")
                            Slider(value: $lamp.hue, in: 0...359, step: 1, onEditingChanged: { editing in
                                if !editing { lamp.send("set_hsv", [Int(lamp.hue), Int(lamp.saturation), "smooth", 300]) }
                            }).tint(Color(hue: lamp.hue / 360, saturation: 1, brightness: 1))
                            Text("Saturation")
                            Slider(value: $lamp.saturation, in: 0...100, step: 1, onEditingChanged: { editing in
                                if !editing { lamp.send("set_hsv", [Int(lamp.hue), Int(lamp.saturation), "smooth", 300]) }
                            })
                        } else {
                            Slider(value: $lamp.temperature, in: 1700...6500, step: 50, onEditingChanged: { editing in
                                if !editing { lamp.send("set_ct_abx", [Int(lamp.temperature), "smooth", 300]) }
                            }).tint(.orange)
                        }
                    }.card()
                    if !lamp.message.isEmpty { Text(lamp.message).foregroundStyle(.orange).font(.footnote) }
                }.padding()
            }.background(Color.black).foregroundStyle(.white)
                .navigationTitle("Dobi").toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Refresh") { lamp.refresh() } }
                    ToolbarItem(placement: .navigationBarTrailing) { Button { showingSettings = true } label: { Image(systemName: "ellipsis") } }
                }.sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        Form {
                            TextField("Lamp IP address", text: $lamp.ip).keyboardType(.decimalPad).autocorrectionDisabled()
                            Text("Connect your iPhone and lamp to the same Wi-Fi.")
                        }.navigationTitle("Settings").toolbar {
                            Button("Done") { showingSettings = false; lamp.refresh() }
                        }
                    }
                }.onAppear { if lamp.ip.isEmpty { showingSettings = true } else { lamp.refresh() } }
        }.preferredColorScheme(.dark)
    }
}

extension View {
    func card() -> some View {
        self.padding(24).background(Color(white: 0.10)).clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
