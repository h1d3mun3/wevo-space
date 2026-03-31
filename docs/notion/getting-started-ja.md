# wevo Getting Started

wevo は P256 ECDSA 署名を使って「誰が何に同意したか」を証明するiOSアプリです。
署名はデバイス上のKeychainで行われ、Proposeの保存とマルチパーティ同期にはwevo-spaceサーバーが必要です。

> **対象読者:** iOSエンジニア向けのTestFlightベータ版ドキュメントです。

---

## なぜwevoを作ったか

二者間で合意が成立したとき、その記録は多くの場合、サードパーティのプラットフォームの中にしか存在しません。フリーランスのマーケットプレイス、シェアサービス、プロジェクト管理ツール。そのプラットフォームが終了したり、ルールが変わったり、単に使わなくなったりしたとき、その履歴は消えてしまいます。

ほとんどの信頼・評判システムには、同じ根本的な問題があります：

- **不透明** — スコアや評価がどう算出されるか見えない
- **移植不可** — 自分の履歴を他の場所に持ち出せない
- **プラットフォーム所有** — 何が重要で何が重要でないかをサービスが決める

wevoは、そこへの別のアプローチを探るプロジェクトです。

信頼をスコアとして計算するのではなく、*実際に起きたこと*を記録します。提案がなされ、双方が署名し、合意が履行された。それぞれの出来事は当事者によって暗号学的に署名され、自分のデバイスに保存され、プラットフォームではなく自分が所有します。

名前はそのアイデアを表しています：**W**eb of **E**ndorsed **V**erifiable **O**aths（保証された検証可能な誓約のウェブ）。スコアでも評価でもなく、自分が持ち運べる署名付きのコミットメントです。

> これは完成したプロダクトでも正式なプロトコルでもありません。一つの実験です――*合意の記録が、それを交わした人たちのものであったとしたら？* という問いへの探求です。

---

## 目次

1. [アーキテクチャ概要](#1-アーキテクチャ概要)
2. [セットアップ](#2-セットアップ)
3. [基本ワークフロー](#3-基本ワークフロー)
4. [技術補足](#4-技術補足)
5. [既知の制限・注意事項](#5-既知の制限注意事項)

---

## 1. アーキテクチャ概要

### 登場する概念

| 概念 | 説明 |
|------|------|
| **Identity** | あなた自身を表すP256署名キーペア。Keychainに保存される。複数持てる |
| **Space** | Proposeをまとめるグループ。wevo-spaceサーバーのURLと紐づく |
| **Contact** | 相手の公開鍵（JWK形式）を保存したもの。Propose送信先に使う |
| **Propose** | 多者間で署名し合うメッセージ（1 creator + n counterparties）。本文はローカルのみ保存 |

### データの流れ

```
[あなた]                              [相手]
  |                                     |
  | ① Identityを作成（Keychain）         |
  |                                     |
  | ②── .wevo-identity を AirDrop ─────▶ |
  |       (相手がContactとして保存)       |
  |                                     |
  | ③ Proposeを作成・署名               |
  |                                     |
  | ④── .wevo-propose を AirDrop ──────▶ |
  |                                     |
  |              ⑤ 相手がProposeに署名   |
  |                                     |
  | ⑥ 双方でHonor / Part / Dissolve      |
```

### wevo と wevo-space の関係

- **wevo（このアプリ）:** クライアント。署名の生成・検証・ローカル保存を担う
- **wevo-space:** Vaporで動くバックエンドサーバー。署名済みのハッシュを管理し、複数デバイス間の同期を仲介する
- **wevo-space連携:** 署名はデバイス上で行われる。署名済みデータは各操作後にwevo-spaceサーバーへ送信される

---

## 2. セットアップ

### 2-1. Identityを作成する

Identity はあなたの署名キーです。最初に必ず1つ作成してください。

1. サイドバー下部の **Manage Keys** をタップ
2. 右上の **+** ボタンをタップ
3. ニックネームを入力（例: `Yamada Taro (iPhone)`）
4. **Create** をタップ

内部的には `P256.Signing.PrivateKey` が生成され、Keychainに保存されます。
公開鍵はJWK形式で保持され、最初の8バイトのSHA256ハッシュがフィンガープリントとして表示されます。

> **注意:** Identityのエクスポート（後述）には生体認証が必要です。Face ID / Touch IDが設定されていることを確認してください。

### 2-2. Spaceを作成する

Space は Propose を管理するグループです。プロジェクトや取引単位で作成します。

1. サイドバーの **+** ボタンをタップ
2. Space名を入力（例: `プロジェクトA`）
3. wevo-space サーバーの URL を入力（例: `https://your-server.example.com`）
4. デフォルトで使うIdentityを選択（後から変更可）
5. **Add** をタップ

---

## 3. 基本ワークフロー

### 3-1. Contactを登録する（相手の公開鍵を受け取る）

Proposeを作成するには相手の公開鍵が必要です。まず相手にContactファイルを送ってもらいます。

**相手側の操作（公開鍵を送る）:**

1. **Manage Keys** → 共有したいIdentityをタップ
2. **Share as Contact** をタップ
3. AirDrop で送信

**自分側の操作（受け取る）:**

1. AirDropで `.wevo-contact` ファイルを受け取る
2. 自動的にContactとして保存される
3. Contacts一覧で公開鍵とフィンガープリントを確認できる

> **フィンガープリントの照合を推奨:** 公開鍵のなりすましを防ぐため、フィンガープリントを別の手段（口頭・Slack等）で相手と確認してください。

---

### 3-2. Proposeを作成して送る

1. 対象のSpaceを開く
2. **Create Propose** をタップ
3. 以下を設定する:
   - **Identity:** 自分の署名に使うIdentityを選択
   - **Counterparty:** 相手のContactを選択
   - **Message:** 合意内容を入力（本文はローカルのみ保存されます）
4. **Create** をタップ

作成時に内部で以下の署名対象メッセージが構築されます:

```
"proposed." + proposeId + contentHash + creatorPublicKey + counterpartyPublicKeys(ソート&結合) + createdAt
```

- ローカルのSwiftDataに保存される
- wevo-spaceサーバーへのPOSTが試みられる（失敗してもローカル保存は維持）

**Proposeを相手に送る:**

1. 作成したProposeをタップ
2. **Export** → AirDrop で相手に `.wevo-propose` を送る

---

### 3-3. Proposeを受け取って署名する

1. AirDropで `.wevo-propose` ファイルを受け取る
2. インポート先のSpaceを選択する
3. Proposeが **Active** タブに表示される（ステータス: `proposed`）
4. Proposeをタップ → **Sign** をタップ
5. 署名に使うIdentityを選択（Creatorが指定したCounterpartyの公開鍵と一致するIdentityのみ表示される）

署名時の署名対象メッセージ:

```
"signed." + proposeId + contentHash + signerPublicKey + timestamp
```

署名後のステータスは `signed` になります。

**署名をサーバーに送信する:**

署名後に **Sync to Server** をタップすると、wevo-spaceに署名が送信されます。
相手がサーバー経由で署名を受け取ることができます。

---

### 3-4. Honor / Part / Dissolve

Proposeが `signed` 状態になった後、以下のアクションが取れます。

| アクション | 意味 | 署名対象メッセージ |
|-----------|------|------|
| **Honor** | 双方が合意を完了したことを表明 | `"honored." + proposeId + contentHash + publicKey + timestamp` |
| **Part** | いずれかが離脱を表明（即座にparted遷移） | `"parted." + proposeId + contentHash + publicKey + timestamp` |
| **Dissolve** | Proposeを破棄（proposed状態のみ） | `"dissolved." + proposeId + contentHash + publicKey + timestamp` |

- `honored` / `parted` になるとCompletedタブに移動する
- すべての状態遷移はサーバー（wevo-space）に送信される

---

## 4. 技術補足

### 署名の仕組み

| 項目 | 内容 |
|------|------|
| アルゴリズム | P256 ECDSA（Apple CryptoKit） |
| 公開鍵形式 | JWK（JSON Web Key） |
| 署名エンコード | Base64 DER |
| ハッシュ | SHA256（メッセージ本文のcontentHash） |

サーバーにはcontentHash（SHA256）のみ送信されます。**メッセージ本文はサーバーに送られません。**
プライバシー上の理由から、本文はローカルSwiftDataにのみ保存されます。

### ファイル形式

すべてJSONです。

| 拡張子 | 内容 |
|--------|------|
| `.wevo-propose` | Proposeデータ（本文・署名含む） |
| `.wevo-identity` | Identityデータ（**秘密鍵含む。取り扱い注意**） |
| `.wevo-contact` | 公開鍵のみ（安全に共有可能） |

### 永続化

| データ | 保存先 |
|--------|--------|
| Identityの秘密鍵 | Keychain（iCloud Keychain同期） |
| Propose / Space / Contact | SwiftData（iCloud同期） |
| メッセージ本文 | SwiftData（ローカルのみ） |

### wevo-space API エンドポイント

| メソッド | パス | 内容 |
|---------|------|------|
| POST | `/v1/proposes` | Propose作成 |
| PATCH | `/v1/proposes/:id/sign` | 署名 |
| PATCH | `/v1/proposes/:id/honor` | Honor |
| PATCH | `/v1/proposes/:id/part` | Part |
| DELETE | `/v1/proposes/:id` | Dissolve |
| GET | `/v1/proposes/:id` | 取得 |
| GET | `/v1/proposes?publicKey=...` | 一覧 |

---

## 5. 既知の制限・注意事項

- **Counterpartyは1名のみ:** 現在のPropose作成UIは2者間（Creator + 1 Counterparty）のみ対応
- **本文の復元不可:** `.wevo-propose` ファイルを削除してサーバーしか残っていない場合、本文は復元できない（サーバーにはハッシュのみ）
- **HTTP許可（テスト版のみ）:** `NSAllowsArbitraryLoads: true` が有効。本番リリースまでにHTTPS必須化予定
- **テストデータの消去:** TestFlight版はSwiftDataのスキーマ変更時にデータが消える可能性がある
- **2台以上推奨:** Proposeの署名フローを試すには2台のiOSデバイスが必要

---

*このドキュメントはwevo TestFlight Beta向けです。フィードバックはTestFlightのフィードバック機能からお送りください。*
