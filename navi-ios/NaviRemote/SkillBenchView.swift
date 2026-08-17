import SwiftUI

/// Bench test for all sixteen firmware skills.
///
/// The issue asks for every skill to be classified table-safe or floor-only "by an actual
/// bench test". No amount of code can decide that — `spin` sounds harmless and may walk the
/// robot off a table, and `be_cute` has never been run at all. What code *can* do is make
/// the test one tap, record what happened, and let everything downstream read the record:
/// the storytelling ambient pool, the companion's reactions and the block palette all take
/// their answer from here.
///
/// Until a skill is recorded as table-safe it does not fire with a phone on the robot's back.
struct SkillBenchView: View {
    @ObservedObject var ble: NaviBLE
    @Environment(\.dismiss) private var dismiss
    @State private var lastRun: String?
    /// Recorded verdicts live in UserDefaults; this only exists to force a redraw.
    @State private var revision = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Put the robot where you will actually use it, with the phone on its back. Run a skill, watch it, then record what it did. Only skills recorded as table-safe are ever used on a table.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !ble.motionAllowed {
                        Text(ble.link.isReady
                             ? "Not armed — turn on the safety gate in Control, or clear a latched e-stop."
                             : "Not connected.")
                            .font(.caption.bold()).foregroundStyle(.orange)
                    }
                }

                Section("The sixteen skills") {
                    ForEach(SkillCatalog.all) { skill in
                        row(skill)
                    }
                }

                Section {
                    Button("Copy the record") {
                        UIPasteboard.general.string = SkillCatalog.report
                    }
                    Button("Clear every verdict", role: .destructive) {
                        SkillCatalog.clearVerdicts()
                        revision += 1
                    }
                } footer: {
                    Text("The record is what goes in the issue. Anything still untested is untested — do not classify a skill from its name.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Skill bench")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { ble.stopDriving(reason: "left the bench"); dismiss() }
                }
            }
            .id(revision)
        }
    }

    private func row(_ skill: RobotSkill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(skill.name).font(.body.monospaced().weight(.medium))
                Spacer()
                Text(SkillCatalog.verdict(skill.name).label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(colour(for: SkillCatalog.verdict(skill.name)).opacity(0.18),
                                in: Capsule())
                    .foregroundStyle(colour(for: SkillCatalog.verdict(skill.name)))
            }
            Text(skill.note).font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    ble.sendSkill(skill.name)
                    lastRun = skill.name
                } label: {
                    Label("Run", systemImage: "play.fill").font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.motionAllowed)

                if lastRun == skill.name {
                    ForEach([SkillVerdict.tableSafe, .floorOnly, .noResponse]) { verdict in
                        Button(verdict.label) {
                            SkillCatalog.record(verdict, for: skill.name)
                            revision += 1
                        }
                        .buttonStyle(.bordered).font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func colour(for verdict: SkillVerdict) -> Color {
        switch verdict {
        case .tableSafe:  .green
        case .floorOnly:  .orange
        case .noResponse: .red
        case .untested:   .secondary
        }
    }
}
