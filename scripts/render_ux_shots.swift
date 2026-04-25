#!/usr/bin/env swift
import Foundation
import SwiftUI
import AppKit

struct AddServerShotView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.16), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 14) {
                Text("添加服务器")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("保存并连接后将静默同步")
                    .foregroundStyle(.secondary)

                Group {
                    row("名称", "Production-1")
                    row("分组", "线上")
                    row("IP 地址", "10.0.0.2")
                    row("端口", "22")
                    row("用户名", "root")
                    row("认证方式", "密码")
                }
                Button("保存并连接") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(28)
            .frame(width: 780)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1), lineWidth: 1))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Text(value)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .foregroundStyle(.white)
    }
}

struct WorkstationShotView: View {
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: 280)
            Divider().background(.white.opacity(0.1))
            center.frame(width: collapsed ? 1100 : 700)
            Divider().background(.white.opacity(0.1))
            if collapsed {
                VStack { Image(systemName: "sidebar.right").rotationEffect(.degrees(180)); Spacer() }
                    .padding(.top, 10)
                    .frame(width: 34)
                    .background(Color.black.opacity(0.35))
            } else {
                right.frame(width: 420)
            }
        }
        .background(
            LinearGradient(colors: [Color(red: 0.03, green: 0.05, blue: 0.12), Color(red: 0.02, green: 0.02, blue: 0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .foregroundStyle(.white)
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务器").font(.headline).padding(.top, 12)
            ForEach(["Web-01", "DB-01", "Cache-01"], id: \.self) { name in
                HStack {
                    Circle().fill(name == "Web-01" ? .green : .gray).frame(width: 8, height: 8)
                    Text(name)
                }
                .padding(8)
                .background(.white.opacity(name == "Web-01" ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.2))
    }

    private var center: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("终端会话").font(.headline)
                Spacer()
                Text("状态：终端在线")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<80, id: \.self) { idx in
                        Text(idx % 2 == 0 ? "yes yes yes yes | chunk \(idx)" : "[monitor] cpu=42.3% mem=67.8% docker=3")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(12)
        }
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("监控 + SFTP").font(.headline).padding(.top, 12)

            GroupBox("系统监控") {
                VStack(alignment: .leading) {
                    Text("CPU 42.3%   内存 67.8%   磁盘 54.1%")
                    ProgressView(value: 0.42).tint(.blue)
                    ProgressView(value: 0.68).tint(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groupBoxStyle(.automatic)

            GroupBox("SFTP") {
                VStack(alignment: .leading) {
                    Text("/var/www")
                    Text("index.html    12 KB")
                    Text("app.log       3.2 MB")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Docker") {
                VStack(alignment: .leading) {
                    Text("● nginx      CPU 4.1%")
                    Text("● postgres   CPU 6.9%")
                    Text("● redis      CPU 1.2%")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.22))
    }
}

func render<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
    try await MainActor.run {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "render", code: 1)
        }
        try png.write(to: url)
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("Build/Snapshots", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let shot1 = outDir.appendingPathComponent("shot1_add_server.png")
let shot2 = outDir.appendingPathComponent("shot2_workstation_full.png")
let shot3 = outDir.appendingPathComponent("shot3_terminal_immersive.png")

try await render(AddServerShotView(), size: CGSize(width: 1600, height: 980), to: shot1)
try await render(WorkstationShotView(collapsed: false), size: CGSize(width: 1600, height: 980), to: shot2)
try await render(WorkstationShotView(collapsed: true), size: CGSize(width: 1600, height: 980), to: shot3)

print("[完成] 截图输出:\n\(shot1.path)\n\(shot2.path)\n\(shot3.path)")
