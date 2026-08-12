import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: MonitorService

    @State private var showTestResult = false
    @State private var testResultMessage = ""
    @State private var sendingTest = false
    @State private var tempAlert = false
    @State private var charge80Alert = false
    @State private var charge20Alert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                SettingsCard(title: "监测", icon: "waveform.path.ecg", tint: .blue) {
                    toggleRow(
                        title: "自动监测与预警",
                        icon: "bolt.fill",
                        tint: .blue,
                        isOn: Binding(
                            get: { settings.monitoringEnabled },
                            set: { settings.monitoringEnabled = $0 }
                        )
                    )

                    Divider()
                    toggleRow(
                        title: "后台监测",
                        icon: "clock.fill",
                        tint: .teal,
                        isOn: Binding(
                            get: { monitor.isMonitoring },
                            set: { enabled in
                                if enabled {
                                    monitor.start()
                                } else {
                                    monitor.stop()
                                }
                            }
                        )
                    )
                    #if os(macOS)
                    Divider()
                    toggleRow(
                        title: "窗口置顶",
                        icon: "pin.fill",
                        tint: .purple,
                        isOn: Binding(
                            get: { settings.windowOnTop },
                            set: { settings.windowOnTop = $0 }
                        )
                    )
                    #endif
                }

                SettingsCard(title: "邮件提醒（SMTP）", icon: "envelope.fill", tint: .orange) {
                    fieldRow("服务器") {
                        TextField("smtp.example.com", text: Binding(
                            get: { settings.smtpHost },
                            set: { settings.smtpHost = $0 }
                        ))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                    }

                    fieldRow("端口") {
                        HStack {
                            TextField("465", text: Binding(
                                get: { String(settings.smtpPort) },
                                set: {
                                    settings.smtpPort = Int($0) ?? 465
                                }
                            ))
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            Text("SSL")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    fieldRow("账号") {
                        TextField("you@example.com", text: Binding(
                            get: { settings.smtpUser },
                            set: { settings.smtpUser = $0 }
                        ))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        #endif
                    }

                    fieldRow("授权码") {
                        SecureField("", text: Binding(
                            get: { settings.smtpPassword },
                            set: { settings.smtpPassword = $0 }
                        ))
                    }

                    fieldRow("发件人") {
                        TextField("IntelGuardian（可选）", text: Binding(
                            get: { settings.smtpSender },
                            set: { settings.smtpSender = $0 }
                        ))
                    }

                    fieldRow("收件邮箱") {
                        TextField("you@example.com", text: Binding(
                            get: { settings.recipient },
                            set: { settings.recipient = $0 }
                        ))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        #endif
                    }

                    Divider()

                    HStack {
                        Text("测试邮件")
                            .frame(width: labelWidth, alignment: .trailing)
                        if sendingTest {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("发送测试邮件") {
                                sendTestEmail()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(!settings.isEmailConfigured)
                        }
                        Spacer(minLength: 0)
                    }

                    if showTestResult {
                        Text(testResultMessage)
                            .font(.footnote)
                            .foregroundColor(testResultMessage.contains("成功") ? .green : .red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, labelWidth + 8)
                    }
                }

                SettingsCard(title: "预警阈值", icon: "gauge.with.dots.needle.50percent", tint: .red) {
                    #if os(iOS)
                    toggleRow(
                        title: "发热预警",
                        icon: "thermometer.high",
                        tint: .red,
                        isOn: Binding(
                            get: { tempAlert },
                            set: {
                                tempAlert = $0
                                settings.notifyBatteryTemp = $0
                            }
                        )
                    )

                    HStack(spacing: 8) {
                        Image(systemName: "thermometer.high")
                            .foregroundStyle(.red)
                            .frame(width: 18)
                        Text("热状态阈值")
                            .lineLimit(1)
                            .fixedSize()
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.thermalStateThresholdRaw },
                            set: {
                                settings.thermalStateThresholdRaw = $0
                            }
                        )) {
                            ForEach(ThermalStateLevel.allCases, id: \.self) { state in
                                Text(state.label).tag(state.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    #else
                    toggleRow(
                        title: "电池温度过高预警",
                        icon: "thermometer.high",
                        tint: .red,
                        isOn: Binding(
                            get: { tempAlert },
                            set: {
                                tempAlert = $0
                                settings.notifyBatteryTemp = $0
                            }
                        )
                    )

                    HStack(spacing: 8) {
                        Image(systemName: "thermometer.high")
                            .foregroundStyle(.red)
                            .frame(width: 18)
                        Text("高温阈值")
                            .lineLimit(1)
                            .fixedSize()
                        Spacer()
                        Text("\(String(format: "%.0f", settings.highBatteryTemp)) °C")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                        Stepper("", value: Binding(
                            get: { settings.highBatteryTemp },
                            set: {
                                settings.highBatteryTemp = $0
                            }
                        ), in: 30...80, step: 1)
                        .labelsHidden()
                    }
                    #endif

                    Divider()

                    toggleRow(
                        title: "充电时电量高于 80% 提醒",
                        icon: "battery.75percent",
                        tint: .green,
                        isOn: Binding(
                            get: { charge80Alert },
                            set: {
                                charge80Alert = $0
                                settings.notifyCharge80 = $0
                            }
                        )
                    )

                    toggleRow(
                        title: "未充电且电量低于 20% 提醒",
                        icon: "battery.25percent",
                        tint: .orange,
                        isOn: Binding(
                            get: { charge20Alert },
                            set: {
                                charge20Alert = $0
                                settings.notifyCharge20 = $0
                            }
                        )
                    )
                }

                SettingsCard(title: "关于", icon: "info.circle.fill", tint: .purple) {
                    if #available(iOS 16.0, macOS 13.0, *) {
                        LabeledContent("版本") {
                            Text("1.0")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack {
                            Text("版本")
                            Spacer()
                            Text("1.0")
                                .foregroundColor(.secondary)
                        }
                    }
                    #if os(macOS)
                    Text("在 macOS 上可读取 CPU 与电池温度（经 SMC）；iOS 由于系统限制无法读取温度，仅监测电量。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #else
                    Text("iOS 由于系统限制无法读取 CPU 与电池温度，改为监测设备热状态（正常 / 轻微升温 / 严重发热 / 临界高温）。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                }
            }
            .padding(20)
            #if os(macOS)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            #endif
        }
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color.black.ignoresSafeArea())
        #endif
        .onAppear(perform: loadBooleans)
    }

    // MARK: - Header

    private var header: some View {
        Text("IntelGuardian 设置")
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    // MARK: - Reusable rows

    private var labelWidth: CGFloat { 72 }

    @ViewBuilder
    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
                .foregroundColor(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func toggleRow(title: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
            }
        }
        .toggleStyle(.switch)
        .tint(tint)
    }

    // MARK: - Actions

    private func loadBooleans() {
        tempAlert = settings.notifyBatteryTemp
        charge80Alert = settings.notifyCharge80
        charge20Alert = settings.notifyCharge20
    }

    private func sendTestEmail() {
        sendingTest = true
        let samples = monitor.store.recentSamples(hours: 3)
        Task {
            let outcome = await EmailService(settings: settings).sendTest(samples: samples)
            await MainActor.run {
                sendingTest = false
                switch outcome {
                case .sent:
                    testResultMessage = "发送成功"
                case .notConfigured:
                    testResultMessage = "邮件配置不完整，请填写 SMTP 与收件信息"
                case .failed(let reason):
                    testResultMessage = "发送失败：\(reason)"
                }
                showTestResult = true
            }
        }
    }
}

// MARK: - Settings card container

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            Divider()
            content()
        }
        .padding(16)
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        )
        #else
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        #endif
    }
}
