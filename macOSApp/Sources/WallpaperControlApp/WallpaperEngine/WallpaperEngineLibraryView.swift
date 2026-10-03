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
            .frame(maxWidth: 360)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Library")
            Spacer()
            if model.isImporting {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelImport() }.buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            } else {
                if model.libraryIsSelected {
                    Button { Task { await model.refreshLocalLibrary() } } label: {
                        if model.isScanningLibrary { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
                    .disabled(model.isScanningLibrary)
                    .help("Refresh local Wallpaper Engine library")
                    .accessibilityLabel("Refresh Wallpaper Engine library")
                }
                Button {
                    if model.libraryIsSelected { model.chooseLibraryDirectory() }
                    else { model.chooseImport() }
                } label: {
                    Label(model.libraryIsSelected ? "Library Folder…" : "Import Wallpaper Engine…",
                          systemImage: model.libraryIsSelected ? "folder.badge.plus" : "square.and.arrow.down")
                        .frame(height: 18)
                }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: false))
            }
        }
    }

    private func libraryButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                Text(title).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 18)
        }
        .buttonStyle(AuraGlassButtonStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct WallpaperEngineLibraryRows: View {
    @ObservedObject var model: WallpaperEngineViewModel
    @Environment(\.adaptiveGlassAppearance) private var appearance
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = model.message { Text(message).font(.caption).lineLimit(3) }
            if !model.libraryWarnings.isEmpty {
                Label("Some library folders could not be read", systemImage: "exclamationmark.triangle")
                    .font(.caption).help(model.libraryWarnings.joined(separator: "\n"))
            }
            if model.libraryCount == 0 {
                Text(model.isScanningLibrary ? "Finding local Wallpaper Engine wallpapers…" :
                     "No local Wallpaper Engine projects found. Connect the disk with your Steam library, or use Library Folder once for a custom location.")
                    .font(.caption).foregroundStyle(appearance.centerTextTone.secondaryTextColor)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.localProjects) { candidate in
                            WallpaperEngineLibraryRow(title: candidate.title, type: candidate.type,
                                previewURL: candidate.previewURL, rootURL: candidate.url,
                                entry: candidate.entryPath ?? candidate.url.lastPathComponent,
                                warnings: candidate.warnings, failure: candidate.error,
                                enabled: candidate.supported && !model.isImporting,
                                preview: { model.previewLocalProject(candidate) },
                                properties: candidate.supported && candidate.type == "web"
                                    ? { model.previewLocalProject(candidate, editProperties: true) } : nil)
                        }
                        ForEach(model.managedProjects) { project in
                            WallpaperEngineLibraryRow(title: project.title, type: project.type.rawValue,
                                previewURL: project.previewURL, rootURL: project.rootURL,
                                entry: project.entryPath, warnings: project.warnings,
                                enabled: !model.isImporting,
                                preview: { model.select(project) },
                                properties: project.type == .web
                                    ? { model.select(project); model.showsProperties = true } : nil)
                        }
                    }
                }.frame(maxHeight: 360)
            }
        }
        .task {
            while !Task.isCancelled {
                if !NSApp.isHidden, NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) {
                    await model.refreshLocalLibrary()
                }
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
            }
        }
    }
}

private struct WallpaperEngineLibraryRow: View {
    let title: String
    let type: String
    let previewURL: URL?
    let rootURL: URL
    let entry: String
    let warnings: [String]
    var failure: String? = nil
    let enabled: Bool
    let preview: () -> Void
    var properties: (() -> Void)? = nil
    @Environment(\.adaptiveGlassAppearance) private var appearance

    var body: some View {
        HStack(spacing: 12) {
            CatalogPreviewImage(url: previewURL, title: title, referer: nil)
                .frame(width: 140, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(type.capitalized) · Wallpaper Engine").font(.caption)
                    .foregroundStyle(appearance.centerTextTone.secondaryTextColor)
                Text(entry).font(.caption2).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(appearance.centerTextTone.secondaryTextColor)
                if let failure {
                    Label(["video", "web"].contains(type) ? "Project unavailable" : "Not supported",
                          systemImage: "exclamationmark.triangle").font(.caption2).help(failure)
                } else if !warnings.isEmpty {
                    Label("Compatibility notes", systemImage: "info.circle").font(.caption2)
                        .help(warnings.joined(separator: "\n"))
                }
            }
            Spacer(minLength: 10)
            VStack(spacing: 6) {
                Button(action: preview) { Label("Preview", systemImage: "play.rectangle") }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: true)).disabled(!enabled)
                Button { NSWorkspace.shared.activateFileViewerSelecting([rootURL]) } label: { Label("Open in Finder", systemImage: "folder") }
                    .buttonStyle(AuraGlassButtonStyle(fillWidth: true))
                if let properties {
                    Button("Properties…", action: properties)
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: true)).disabled(!enabled)
                }
            }.frame(width: 142)
        }
        .padding(8).background(AuraGlassInsetCard())
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
