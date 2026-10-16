# Third-party notices

Cloudified preserves the licenses of the components it redistributes or adapts.
Exact source revisions and artifact provenance are recorded in
[dependencies/pins.json](dependencies/pins.json) and
[dependencies/tdlib-vendor.json](dependencies/tdlib-vendor.json).

| Component | Use | Notice |
| --- | --- | --- |
| [PhotosBackup](https://github.com/g8row/PhotosBackup) | Google authentication/client implementation reference and adapted sources | [MIT](licenses/LICENSE-PhotosBackup.txt) |
| [TDLib](https://github.com/tdlib/td) | Telegram native transport | [Boost Software License](licenses/LICENSE-TDLib.txt) |
| [OpenSSL](https://github.com/openssl/openssl) | TDLib cryptography dependency | [License](licenses/LICENSE-OpenSSL.txt) |
| TDLib's SQLite dependency | Native Telegram database | [Notice](licenses/LICENSE-TDSQLite.txt) |

These licenses apply to the respective upstream components. They do not imply
endorsement of Cloudified by their authors or by the services it connects to.

## Additional acknowledgement

[xob0t/gotohp](https://github.com/xob0t/gotohp) (MIT) is an additional Google Photos
implementation reference. Reviewed reference revision:
[`97a5dc02db81f5571ce6b586f478600fcd44dd89`](https://github.com/xob0t/gotohp/tree/97a5dc02db81f5571ce6b586f478600fcd44dd89).
No gotohp source is currently copied into or linked by Cloudified; it is not a
runtime dependency. PhotosBackup remains the pinned Google implementation base.
