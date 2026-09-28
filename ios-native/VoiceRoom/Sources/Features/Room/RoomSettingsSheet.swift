import SwiftUI
import UIKit

/// 房间设置（房主可改房间名 / 背景）
struct RoomSettingsSheet: View {

    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var roomName = ""
    @State private var background: RoomBackground = .aurora
    @State private var showDestroyConfirm = false

    private var isHost: Bool { app.isHost }

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("房间设置")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(VRTheme.text)

                    // 房间号
                    VStack(alignment: .leading, spacing: 7) {
                        Text("房间号（点一下复制）")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)

                        Button {
                            UIPasteboard.general.string = state.room.no
                            app.showToast("房间号已复制：\(state.room.no)", kind: .success)
                        } label: {
                            HStack {
                                Text(state.room.no)
                                    .font(.system(size: 21, weight: .heavy, design: .monospaced))
                                    .foregroundColor(VRTheme.gold)
                                    .tracking(2)
                                Spacer()
                                Text("📋 复制")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(VRTheme.textDim)
                            }
                            .padding(.horizontal, 15)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(VRTheme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // 房间名
                    VStack(alignment: .leading, spacing: 7) {
                        Text("房间名称")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)
                        VRTextField(placeholder: "房间名称", text: $roomName, maxLength: 22)
                            .disabled(!isHost)
                            .opacity(isHost ? 1 : 0.55)
                    }

                    // 背景
                    VStack(alignment: .leading, spacing: 10) {
                        Text("房间背景")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3),
                                  spacing: 9) {
                            ForEach(RoomBackground.allCases) { bg in
                                BackgroundOption(bg: bg, selected: background == bg) {
                                    guard isHost else {
                                        app.showToast("只有房主能修改房间背景", kind: .error)
                                        return
                                    }
                                    withAnimation(.easeOut(duration: 0.16)) { background = bg }
                                }
                            }
                        }
                    }

                    Button("保存") {
                        let n = roomName.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty && n != state.room.name { app.renameRoom(n) }
                        if background.rawValue != state.room.background {
                            app.setRoomBackground(background)
                        }
                        app.showToast("房间设置已保存", kind: .success)
                        dismiss()
                    }
                    .buttonStyle(VRButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(!isHost)
                    .opacity(isHost ? 1 : 0.45)

                    if !isHost {
                        Text("只有房主能修改房间名和背景。你可以把房间号发给朋友，邀请他们进来。")
                            .font(.system(size: 12))
                            .foregroundColor(VRTheme.textMute)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                    }

                    // 危险操作
                    VStack(alignment: .leading, spacing: 10) {
                        Text("其他")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)

                        Button("🚪 离开房间") {
                            app.leaveRoom()
                            dismiss()
                        }
                        .buttonStyle(VRButtonStyle(fullWidth: true))

                        if isHost {
                            Button {
                                showDestroyConfirm = true
                            } label: {
                                Text("💣 解散我的永久房间")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(LinearGradient(colors: [Color(hex: "E0344C"), Color(hex: "A81C3C")],
                                                                 startPoint: .leading, endPoint: .trailing))
                                    )
                                    .shadow(color: Color(hex: "E0344C").opacity(0.35), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .confirmationDialog("解散后房间将永久删除，房间里的所有人都会被请出。确定吗？",
                            isPresented: $showDestroyConfirm, titleVisibility: .visible) {
            Button("解散房间", role: .destructive) {
                app.destroyMyRoom()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            roomName = state.room.name
            background = RoomBackground(safeRaw: state.room.background)
        }
    }
}
