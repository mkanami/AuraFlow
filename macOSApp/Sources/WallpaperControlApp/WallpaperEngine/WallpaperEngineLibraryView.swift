import AppKit
import AuraWallpaperEngineCore
import SwiftUI

struct WallpaperEngineLibrarySwitch: View {
    @ObservedObject var model: WallpaperEngineViewModel
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                libraryButton("AuraFlow", selected: !model.libraryIsSelected) { model.libraryIsSelected = false }
                libraryButton("Wallpaper Engine", selected: model.libraryIsSelected) { model.libraryIsSelected = true }
            }
            .frame(maxWidth: 320)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Library")
            Spacer()
            if model.isImporting {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelImport() }.buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            } else {
                Button { model.chooseImport() } label: { Label("Import Wallpaper Engine…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            }
        }
    }

    private func libraryButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                Text(title).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraGlassButtonStyle(compact: true))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct WallpaperEngineLibraryRows: View {
    @ObservedObject var model: WallpaperEngineViewModel
    @Environment(\.adaptiveGlassAppearance) private var appearance
    var body: some View {
        if let message = model.message { Text(message).font(.caption).lineLimit(3) }
        if model.projects.isEmpty {
            Text("Import a downloaded Wallpaper Engine project folder or project.json. Video and Web are supported.")
                .font(.caption).foregroundStyle(appearance.centerTextTone.secondaryTextColor)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.projects) { project in
                        HStack(spacing: 12) {
                            CatalogPreviewImage(url: project.previewURL, title: project.title, referer: nil)
                                .frame(width: 140, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(project.type == .video ? "Video" : "Web") · Wallpaper Engine").font(.caption)
                                    .foregroundStyle(appearance.centerTextTone.secondaryTextColor)
                                Text(project.entryPath).font(.caption2).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(appearance.centerTextTone.secondaryTextColor)
                                if !project.warnings.isEmpty {
                                    Label("Compatibility notes", systemImage: "info.circle").font(.caption2)
                                        .help(project.warnings.joined(separator: "\n"))
                                }
                            }
                            Spacer(minLength: 10)
                            VStack(spacing: 6) {
                                Button { model.select(project) } label: { Label("Preview", systemImage: "play.rectangle") }
                                    .buttonStyle(AuraGlassButtonStyle(fillWidth: true))
                                Button { NSWorkspace.shared.activateFileViewerSelecting([project.rootURL]) } label: { Label("Open in Finder", systemImage: "folder") }
                                    .buttonStyle(AuraGlassButtonStyle(fillWidth: true))
                                if project.type == .web {
                                    Button("Properties…") { model.select(project); model.showsProperties = true }
                                        .buttonStyle(AuraGlassButtonStyle(fillWidth: true))
                                }
                            }.frame(width: 142)
                        }
                        .padding(8).background(AuraGlassInsetCard())
                    }
                }
            }.frame(maxHeight: 360)
        }
    }
}

struct WallpaperEngineProjectPicker: View {
    @ObservedObject var model: WallpaperEngineViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Wallpaper Engine").font(.title2)
            ScrollView {
                ForEach(model.candidates) { candidate in
                    HStack {
                        Toggle(isOn: Binding(get: { model.selectedCandidates.contains(candidate.id) }, set: { enabled in
                            if enabled { model.selectedCandidates.insert(candidate.id) } else { model.selectedCandidates.remove(candidate.id) }
                        })) { Text(candidate.title) }.disabled(!candidate.supported)
                        Text(candidate.supported ? candidate.type.capitalized : "Unsupported").font(.caption)
                    }.padding(.vertical, 5)
                    if let error = candidate.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 330)
            HStack {
                Button("Cancel") { model.cancelImport() }
                Spacer()
                Button("Import selected") { model.importSelected() }
                    .disabled(model.selectedCandidates.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580)
    }
}

struct WallpaperEnginePropertiesEditor: View {
    @ObservedObject var model: WallpaperEngineViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.selectedProject?.title ?? "Web Properties").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.selectedProject?.properties ?? []) { property in
                        propertyControl(property)
                    }
                    ForEach(model.selectedProject?.warnings ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 350)
            HStack { Spacer(); Button("Done") { model.showsProperties = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 550)
    }
    @ViewBuilder private func propertyControl(_ property: WallpaperEngineProperty) -> some View {
        switch property.type {
        case "bool":
            Toggle(property.title, isOn: Binding(get: { model.values[property.id]?.bool ?? false }, set: { model.setValue(.bool($0), for: property) }))
        case "slider":
            let low = property.definition["min"]?.number ?? 0
            let high = max(low + 0.001, property.definition["max"]?.number ?? 100)
            VStack(alignment: .leading) {
                Text("\(property.title): \(model.values[property.id]?.number ?? low, specifier: "%.2f")")
                Slider(value: Binding(get: { model.values[property.id]?.number ?? low }, set: { model.setValue(.number($0), for: property) }), in: low...high)
            }
        case "textinput":
            TextField(property.title, text: Binding(get: { model.values[property.id]?.string ?? "" }, set: { model.setValue(.string($0), for: property) }))
        case "color":
            ColorPicker(property.title, selection: Binding(get: {
                let values = (model.values[property.id]?.string ?? "0 0 0").split(separator: " ").compactMap { Double($0) }
                return values.count == 3 ? Color(red: values[0], green: values[1], blue: values[2]) : .black
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                model.setValue(.string("\(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent)"), for: property)
            }), supportsOpacity: false)
        case "combo":
            let options = property.definition["options"]?.array ?? []
            Picker(property.title, selection: Binding(get: {
                options.firstIndex { $0.object?["value"] == model.values[property.id] } ?? 0
            }, set: { index in
                if options.indices.contains(index), let value = options[index].object?["value"] { model.setValue(value, for: property) }
            })) {
                ForEach(options.indices, id: \.self) { index in Text(options[index].object?["label"]?.string ?? "Option \(index + 1)").tag(index) }
            }
        default:
            Text("\(property.title) (\(property.type)): not editable").font(.caption).foregroundStyle(.secondary)
        }
    }
}
