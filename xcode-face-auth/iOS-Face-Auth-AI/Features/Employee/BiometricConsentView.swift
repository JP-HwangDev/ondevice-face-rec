//
//  BiometricConsentView.swift
//  FaceAuthApp
//
// 개인정보보호법 제23조 — 생체인식정보(민감정보) 수집·이용 동의
//

import SwiftUI

struct BiometricConsentView: View {
    let onConsent: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    consentTableSection
                    rightsSection
                    warningSection
                }
                .padding(20)
            }
            .navigationTitle("생체정보 수집·이용 동의")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                actionButtons
            }
        }
    }

    // MARK: - 안내 헤더

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("생체인식정보 수집 안내")
                    .font(.headline)
            }
            Text("개인정보보호법 제23조에 따라 생체인식정보(민감정보)를 수집하기 전 별도의 동의를 받습니다. 아래 내용을 확인한 후 동의 여부를 선택해 주세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - 수집·이용 내역 표

    private var consentTableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("수집·이용 내역")

            consentRow(
                title: "수집 항목",
                content: "얼굴 임베딩 벡터 (얼굴 사진을 수치화한 특징값, 512차원)\n※ 원본 얼굴 사진은 저장되지 않습니다"
            )
            Divider().padding(.leading, 16)

            consentRow(
                title: "수집·이용 목적",
                content: "사내 출입 및 출결 관리 시스템 본인 확인"
            )
            Divider().padding(.leading, 16)

            consentRow(
                title: "보유·이용 기간",
                content: "재직 기간 종료 시까지\n(퇴직·계약 만료 시 즉시 삭제)"
            )
            Divider().padding(.leading, 16)

            consentRow(
                title: "처리 위치",
                content: "기기 내부 전용 (온디바이스)\n외부 서버로 전송되지 않습니다"
            )
            Divider().padding(.leading, 16)

            consentRow(
                title: "제3자 제공",
                content: "제공하지 않음"
            )
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - 권리 안내

    private var rightsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("정보주체의 권리")
            Text("• 언제든지 동의를 철회하고 생체정보 삭제를 요청할 수 있습니다.\n• 동의 거부 시 얼굴인식 기능을 이용할 수 없으나, 다른 방법으로 출결 처리가 가능합니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - 주의 사항

    private var warningSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
                .padding(.top, 1)
            Text("본 동의는 해당 직원 본인에게 직접 설명한 후 받아야 합니다. 관리자가 임의로 동의를 대행하는 것은 개인정보보호법 위반입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - 버튼

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                onConsent()
            } label: {
                Text("동의합니다")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue)
                    .cornerRadius(14)
            }

            Button(role: .cancel) {
                onDecline()
            } label: {
                Text("동의하지 않습니다")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - 헬퍼

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func consentRow(title: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .frame(width: 110, alignment: .leading)
                .padding(.leading, 16)
                .padding(.vertical, 12)

            Text(content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
                .padding(.trailing, 16)
        }
    }
}

#Preview {
    BiometricConsentView(onConsent: {}, onDecline: {})
}
