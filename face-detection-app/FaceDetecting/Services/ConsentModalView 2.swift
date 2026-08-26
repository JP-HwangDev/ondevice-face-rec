import SwiftUI

struct ConsentModalView: View {
    let employeeName: String
    let onAgree: (String) -> Void
    let onCancel: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    private let consentVersion = "v1.0-2026-06-19"
    
    var body: some View {
        VStack(spacing: 24) {
            Text("顔データ収集に関する同意")
                .font(.title)
                .bold()
                .multilineTextAlignment(.center)
            
            ScrollView {
                Text("""
                株式会社RSP（以下「当社」）は、個人情報保護法（以下「法」）および関連法令に基づき、顔認証データ（法第2条第1項に定める要配慮個人情報および個人識別符号に該当）の取扱いについて、以下の通りご説明します。

                【収集する情報】
                ・顔画像および顔の特徴量データ（数値化されたベクトル情報）

                【利用目的】
                ・出退勤管理システムにおける本人確認のみに利用します。
                ・上記以外の目的には一切利用しません。

                【保存期間】
                ・在籍中、および退職後1年間保存します。
                ・保存期間経過後は速やかに復元不可能な方法で削除します。

                【第三者提供】
                ・収集した顔認証データは第三者へ提供しません。
                ・ただし法令に基づく開示要求がある場合はこの限りではありません。

                【安全管理措置】
                ・顔特徴量はデバイス内にのみ保存し、外部サーバーへ送信しません。
                ・データへのアクセスは当社システム管理者に限定します。
                ・技術的・組織的安全管理措置を適切に講じています。

                【同意の任意性】
                ・本同意は任意です。同意しない場合でも不利益な取扱いは一切ありません。
                ・ただし同意なき場合、顔認証による出退勤機能はご利用いただけません。

                【同意の撤回・削除・開示請求】
                ・いつでも同意を撤回し、登録データの削除を求めることができます。
                ・保有個人データの開示・訂正・利用停止を請求する権利があります。

                【個人情報管理者・お問い合わせ】
                株式会社RSP　個人情報保護管理者
                https://www.rsp-corp.com/contact/
                """)
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding()
            }
            .frame(maxHeight: 280)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            HStack(spacing: 32) {
                Button(action: {
                    onCancel()
                    dismiss()
                }) {
                    Text("拒否")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red, lineWidth: 1)
                        )
                }
                
                Button(action: {
                    onAgree(employeeName)
                }) {
                    Text("同意する")
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(8)
                }
            }
            
            Text("同意バージョン: \(consentVersion)")
                .font(.caption2)
                .foregroundColor(.gray)
                .padding(.top, 8)
        }
        .padding()
        .presentationDetents([.medium, .large])
    }
}

struct ConsentModalView_Previews: PreviewProvider {
    static var previews: some View {
        ConsentModalView(employeeName: "山田太郎", onAgree: { _ in }, onCancel: {})
    }
}
