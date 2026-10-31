#!/bin/sh
# The voice of voice mode (#2322): Kokoro-82M's Neural Engine build, its 28 American and
# British English voices (Alex, 2026-10-29), and the English front end it reads with (G2P
# and lexicon), about 105 MB, carried inside the Mac window and the Remote, so the app
# downloads nothing. The voices other than af_heart are published as JSON; each is turned
# into the flat fp32 .bin FluidAudio reads, as FluidAudio does on first use (#896). Not in git: fetched from Hugging Face at a pinned revision, each file
# checked against its SHA-256 below, and kept in the build cache that every worktree shares.
#
#   scripts/voice-models.sh            fetch into the cache only
#   scripts/voice-models.sh --carry    an app's build: copy them into its Resources/Voice
#
# With no network and nothing in the cache, a Debug build goes on without the voice (voice
# mode says so); any other configuration fails, so no release ships without it.
set -eu

cache=${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}/voice
kokoroane=FluidInference/kokoro-82m-coreml@2568276a60ff6e7f312afce3dc9e3f07521cb48d
kokoro=FluidInference/kokoro-82m-coreml@e61d9ee79a01ad4ebf6b3d8bcfe2a03f6b8da105

# repo@revision, the file in the repository, where it goes under Voice/, its SHA-256.
files() {
	cat <<EOF
$kokoro G2PDecoder.mlmodelc/analytics/coremldata.bin kokoro/G2PDecoder.mlmodelc/analytics/coremldata.bin dbf1767747fdc188222d467a45b04608b396c76c71db3abb18a5fb3680ef9827
$kokoro G2PDecoder.mlmodelc/coremldata.bin kokoro/G2PDecoder.mlmodelc/coremldata.bin 607e960f19b4d9a30317a5a11869fcce84b300a909fcab2cc756c0d98e2dacd9
$kokoro G2PDecoder.mlmodelc/metadata.json kokoro/G2PDecoder.mlmodelc/metadata.json e54e98484fd60d26f22fd3c4e7fe87b0d92a5d2de1f958cc3c4bb36d4ae06a44
$kokoro G2PDecoder.mlmodelc/model.mil kokoro/G2PDecoder.mlmodelc/model.mil fe647c598e0d9454d360b8ee49a59ae57ca147fc5330863ba84ccb90dce482ad
$kokoro G2PDecoder.mlmodelc/weights/weight.bin kokoro/G2PDecoder.mlmodelc/weights/weight.bin cbaeb4e743359f607ab161af0c6d8a817462fdaec622ee788ef8ef952c5f8214
$kokoro G2PEncoder.mlmodelc/analytics/coremldata.bin kokoro/G2PEncoder.mlmodelc/analytics/coremldata.bin cf7fbd7e7a65529b2d2bf3941e458a0ab6dff7a298bf48e205a1727c81c26a99
$kokoro G2PEncoder.mlmodelc/coremldata.bin kokoro/G2PEncoder.mlmodelc/coremldata.bin 0f14d46ca9fd06c68b4717294575b2b99449e67d40b7a2c56f926bf05cd90b11
$kokoro G2PEncoder.mlmodelc/metadata.json kokoro/G2PEncoder.mlmodelc/metadata.json c8e0cfd7f494ac1b3662ff8f1914b2b45f79ffb2791724cdc0576981996732e1
$kokoro G2PEncoder.mlmodelc/model.mil kokoro/G2PEncoder.mlmodelc/model.mil 8c617e569f37286b056dad800d862dc145be9a95fa9ed43857bb646ba199d7da
$kokoro G2PEncoder.mlmodelc/weights/weight.bin kokoro/G2PEncoder.mlmodelc/weights/weight.bin 6926bcd2827d21fec82839487b987e06f85fd8a6a5bb896bc4f6062461d014ec
$kokoro g2p_vocab.json kokoro/g2p_vocab.json 295ed64b86c2820cd665b0602ae50c6947c0e82ac643082873e0be87dca282ce
$kokoro us_lexicon_cache.json kokoro/us_lexicon_cache.json 6b36ba313202227d6914ad32cd684a0304bd2757e9ec4158ea7bc36ec40e224e
$kokoroane ANE/KokoroAlbert.mlmodelc/analytics/coremldata.bin kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/analytics/coremldata.bin 14a61873d8759a38b79c93f9021ae865f408f56301209a0168dbfc2283265ccd
$kokoroane ANE/KokoroAlbert.mlmodelc/coremldata.bin kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/coremldata.bin 70b6d2f8429229f6800dda9480341669f7ac0eabf05a82934d8632ab2b4b63a6
$kokoroane ANE/KokoroAlbert.mlmodelc/metadata.json kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/metadata.json fe1d005481f646707a948267ac089dfb2cd2ccea7d5827a14c28587eb4c89930
$kokoroane ANE/KokoroAlbert.mlmodelc/model.mil kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/model.mil 2038154d06a20e399a8ae35ec5c9242702cb23db8dd24dde7679cd53708e4eae
$kokoroane ANE/KokoroAlbert.mlmodelc/weights/weight.bin kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/weights/weight.bin 36089a39359b800d3e2c60e5e8ac9217d8f2d1010a8b9273192290e621f1fabc
$kokoroane ANE/KokoroAlignment.mlmodelc/analytics/coremldata.bin kokoro-82m-coreml/ANE/KokoroAlignment.mlmodelc/analytics/coremldata.bin f6074d1039a9151d0f97dc6ec9ee0cd9c7b865f1af646d718ab38b659fa84f3f
$kokoroane ANE/KokoroAlignment.mlmodelc/coremldata.bin kokoro-82m-coreml/ANE/KokoroAlignment.mlmodelc/coremldata.bin 9a0fb4a536f665a052914d7f17b0e6ac80a3614f702e4be87ac0302c1143a4ea
$kokoroane ANE/KokoroAlignment.mlmodelc/metadata.json kokoro-82m-coreml/ANE/KokoroAlignment.mlmodelc/metadata.json 6f610d23b9f93c7f1a968d6a861efa99725a191de696bf1c3be334ead39b7f00
$kokoroane ANE/KokoroAlignment.mlmodelc/model.mil kokoro-82m-coreml/ANE/KokoroAlignment.mlmodelc/model.mil eb3a618bda0cdf95cdffab586ef5c76333d0d0a1dcb881190b3ef414f3421b3e
$kokoroane ANE/KokoroAlignment.mlmodelc/weights/weight.bin kokoro-82m-coreml/ANE/KokoroAlignment.mlmodelc/weights/weight.bin 2e7d69128b59d615fc3d3cf85637a687235fc086b1eb136359adb11a61615f6b
$kokoroane ANE/KokoroNoise_v2.mlmodelc/analytics/coremldata.bin kokoro-82m-coreml/ANE/KokoroNoise_v2.mlmodelc/analytics/coremldata.bin 53af6bf61482f6002bdb6e3a62f30774cde6e96411aebd888222a34b369f3d04
$kokoroane ANE/KokoroNoise_v2.mlmodelc/coremldata.bin kokoro-82m-coreml/ANE/KokoroNoise_v2.mlmodelc/coremldata.bin 9911047f924b41f8b92811c32c50b7c718bd7b0c14842b3bc1b66b9ffe341a19
$kokoroane ANE/KokoroNoise_v2.mlmodelc/metadata.json kokoro-82m-coreml/ANE/KokoroNoise_v2.mlmodelc/metadata.json eb3102217532d952479c6f1b04d26d7ac4cdbc59875b6a23e8aae86e5e02c2bc
$kokoroane ANE/KokoroNoise_v2.mlmodelc/model.mil kokoro-82m-coreml/ANE/KokoroNoise_v2.mlmodelc/model.mil 60233949d896f15ef38aea19afda558935d7569fa77a3ca4babddd3ffe845a36
$kokoroane ANE/KokoroNoise_v2.mlmodelc/weights/weight.bin kokoro-82m-coreml/ANE/KokoroNoise_v2.mlmodelc/weights/weight.bin 1102fc2d31dfcfe3de3978a4c78b65202ff8b0a4d55a9304213bd4e8bda66bc2
$kokoroane ANE/KokoroPostAlbert.mlmodelc/analytics/coremldata.bin kokoro-82m-coreml/ANE/KokoroPostAlbert.mlmodelc/analytics/coremldata.bin 6640044c875505382edbc361cdd56f3f1c30f082953e0f9473a31ae3f71e6c43
$kokoroane ANE/KokoroPostAlbert.mlmodelc/coremldata.bin kokoro-82m-coreml/ANE/KokoroPostAlbert.mlmodelc/coremldata.bin 86de3ab0c1e8c6f8842b57bc24695a5099590c49b864e3fa2737b1fb5b15ba3b
$kokoroane ANE/KokoroPostAlbert.mlmodelc/metadata.json kokoro-82m-coreml/ANE/KokoroPostAlbert.mlmodelc/metadata.json 2e3be1af412a76e340120a01cd04a502666371ada86b1fdaf5a622896e0bf979
$kokoroane ANE/KokoroPostAlbert.mlmodelc/model.mil kokoro-82m-coreml/ANE/KokoroPostAlbert.mlmodelc/model.mil 450b73a3b179e1702e7b2210bad008eac20d58b2d6076e3c2de76290a66e5fef
$kokoroane ANE/KokoroPostAlbert.mlmodelc/weights/weight.bin kokoro-82m-coreml/ANE/KokoroPostAlbert.mlmodelc/weights/weight.bin e4f300a23cc2e05d38680d9fc94681cc722d445076d1d248f83255122ba091c8
$kokoroane ANE/KokoroProsody_v2.mlmodelc/analytics/coremldata.bin kokoro-82m-coreml/ANE/KokoroProsody_v2.mlmodelc/analytics/coremldata.bin 804d7d2e9a8fed345cedb57da61bd27fdd95db22a070cfa7d42ccd4f8e80a443
$kokoroane ANE/KokoroProsody_v2.mlmodelc/coremldata.bin kokoro-82m-coreml/ANE/KokoroProsody_v2.mlmodelc/coremldata.bin db8776a4896f690fd254cdb68a4551c168411c9b3fb98219630215bc3c357986
$kokoroane ANE/KokoroProsody_v2.mlmodelc/model.mil kokoro-82m-coreml/ANE/KokoroProsody_v2.mlmodelc/model.mil e6acad9f44d70b1dba0aea6a5d25ee4edf68fe8f2933399ee81f70ace61cbc8b
$kokoroane ANE/KokoroProsody_v2.mlmodelc/weights/weight.bin kokoro-82m-coreml/ANE/KokoroProsody_v2.mlmodelc/weights/weight.bin 70eea4cd2523992fa1fea840e31ab6f4fdd69c1598e220985a2ae6ea5da1e944
$kokoroane ANE/KokoroTail_v2.mlmodelc/analytics/coremldata.bin kokoro-82m-coreml/ANE/KokoroTail_v2.mlmodelc/analytics/coremldata.bin a06e4b91c2b8a8be3ff701558a5f1f6484921f948202663fe6df78f248d42222
$kokoroane ANE/KokoroTail_v2.mlmodelc/coremldata.bin kokoro-82m-coreml/ANE/KokoroTail_v2.mlmodelc/coremldata.bin 527271f6df56cc308a5f89374c92108aef7b837ab15f0ba4900d555588dbd905
$kokoroane ANE/KokoroTail_v2.mlmodelc/metadata.json kokoro-82m-coreml/ANE/KokoroTail_v2.mlmodelc/metadata.json 7708ecc145eecf8e3ef5ef8979ea7a4f77d04c8da787454c6d9190e5300fc50b
$kokoroane ANE/KokoroTail_v2.mlmodelc/model.mil kokoro-82m-coreml/ANE/KokoroTail_v2.mlmodelc/model.mil b0b8fd573bac76ba7eb85730eeb25538fc7f1c666ecbf939fd4b3a4ad4495ad7
$kokoroane ANE/KokoroTail_v2.mlmodelc/weights/weight.bin kokoro-82m-coreml/ANE/KokoroTail_v2.mlmodelc/weights/weight.bin 8ede31ec20df7d86a124287ac12d13507651e2a693e9d4f35f0e7f92cba422c7
$kokoroane ANE/KokoroVocoder.mlmodelc/analytics/coremldata.bin kokoro-82m-coreml/ANE/KokoroVocoder.mlmodelc/analytics/coremldata.bin 1cc4f1e6436597c6d458a845570d9d0ace458813ff90f225d08e0e713496b463
$kokoroane ANE/KokoroVocoder.mlmodelc/coremldata.bin kokoro-82m-coreml/ANE/KokoroVocoder.mlmodelc/coremldata.bin 71bac80d2f2f077fefc0d66cdc39c0faaa96540b3a6149093ef29de01b1f8764
$kokoroane ANE/KokoroVocoder.mlmodelc/metadata.json kokoro-82m-coreml/ANE/KokoroVocoder.mlmodelc/metadata.json a8e768f151225a52476d35f6ab90805ae00f1f78b83be4ca21327029c800c183
$kokoroane ANE/KokoroVocoder.mlmodelc/model.mil kokoro-82m-coreml/ANE/KokoroVocoder.mlmodelc/model.mil 52f2febec45094e78a5948a3a47f023be8fc57cfd48cc99e8d4c358a13674ef2
$kokoroane ANE/KokoroVocoder.mlmodelc/weights/weight.bin kokoro-82m-coreml/ANE/KokoroVocoder.mlmodelc/weights/weight.bin 6d1f96eb50218ab687b12d6d862d2ae854c12b7165c3cd9b6b5cef261ef02ff1
$kokoroane ANE/af_heart.bin kokoro-82m-coreml/ANE/af_heart.bin d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b
$kokoroane ANE/vocab.json kokoro-82m-coreml/ANE/vocab.json 8d65b0188b77eafc60751dac42bbac7ab5f5685074af44db91d1877b42dc1d7c
$kokoroane voices/af_alloy.json kokoro-voices/af_alloy.json f581276e925292c320b69041337c284a9990e700d8a0710f41de8588ae2a8106
$kokoroane voices/af_aoede.json kokoro-voices/af_aoede.json d8c03663a645948f034e79c51f07edd9d6e4ffe0c12dc5643fa4e4e8ecba17eb
$kokoroane voices/af_bella.json kokoro-voices/af_bella.json e7bdbe207b927d1e59556dcda69b976cbbdc87be5e4affeea5bf030fca80e55c
$kokoroane voices/af_jessica.json kokoro-voices/af_jessica.json bc65117b66e2ed1db0f4e4ef7325cd7ec6fc8eea2148076ff456639ccc0ab454
$kokoroane voices/af_kore.json kokoro-voices/af_kore.json ba2ba219150d210bff86557d0b20a0c10aa72a625f55578e2728807c13c6a302
$kokoroane voices/af_nicole.json kokoro-voices/af_nicole.json a52212b76eeabff2e7723439649ef55e244d0a16477816dfb84c3f0e632d4323
$kokoroane voices/af_nova.json kokoro-voices/af_nova.json 54d03024723e2f6c0cf01b2e685712155d24ffaa5275443367f5725416ec7c4d
$kokoroane voices/af_river.json kokoro-voices/af_river.json 9bfe33a344bbdf429eb2ac1542e55fe581c3a5684bf1b8fc2f730da4631a5774
$kokoroane voices/af_sarah.json kokoro-voices/af_sarah.json 3c5270deda46faf0130837100a51ccbe39f5c268886f59e31aca52687b876ecf
$kokoroane voices/af_sky.json kokoro-voices/af_sky.json 3c319a30d8e981bd91d9199b36371321536dd860158058fc40dfe2965fb46861
$kokoroane voices/am_adam.json kokoro-voices/am_adam.json 7a88a16aa63381d00f8c35cab810fa5135ec3b0575f50f823b2ec0e13852a226
$kokoroane voices/am_echo.json kokoro-voices/am_echo.json 39ba7bc17b4fbf778183904840140f3f5da2472b9c0f1b269ea9aa7a5b0e5e9f
$kokoroane voices/am_eric.json kokoro-voices/am_eric.json e075c8b7a9f2fe63c685b7434086b5c280589b3353ba5410337fb6db152f88a6
$kokoroane voices/am_fenrir.json kokoro-voices/am_fenrir.json 7c983af1d3317de8a821ea46ab3cb8f1839624f91adb66bb5f24043a777078ba
$kokoroane voices/am_liam.json kokoro-voices/am_liam.json 11509116ebde425f0c2a21ff052d6849ef4ad47fdb7d7b5287f703fd4a102dfa
$kokoroane voices/am_michael.json kokoro-voices/am_michael.json ec6e03f1fc30c11020ade45f587a64e1b8c51c08e8ab6f59bdf089f410c2b924
$kokoroane voices/am_onyx.json kokoro-voices/am_onyx.json efd106cf86c25b2cb0ee68f7e2d3d96e7e3ebd9901d7376e4c0e2db8a6dbffb5
$kokoroane voices/am_puck.json kokoro-voices/am_puck.json 3f603430c6050de2b00626aa9509fdfcd5a119b33dee88a05d7174897bf12694
$kokoroane voices/am_santa.json kokoro-voices/am_santa.json 0ef4b7da155ad27e72987b530cce6fc92070b7a4fd0f5ff06bd819321feb3357
$kokoroane voices/bf_alice.json kokoro-voices/bf_alice.json 1c807b5fabe86152d04c4bb22a8d6ca75b282cd829c458dad661e19efdbe9ef5
$kokoroane voices/bf_emma.json kokoro-voices/bf_emma.json 2b7f73a1af7bd195d1c4bae834cc96d4e319e26abb4ddbe4c7c43485789dda69
$kokoroane voices/bf_isabella.json kokoro-voices/bf_isabella.json 63a73d3256cb932492c4d3a3175860b774b149c814aeee480365baf3d46ad3a9
$kokoroane voices/bf_lily.json kokoro-voices/bf_lily.json 3f7352e572151d614f7d61885b4cbe59a77c2e1dc761830bcd445ff1db36fc32
$kokoroane voices/bm_daniel.json kokoro-voices/bm_daniel.json 1b47d51a08f11b0726dcefbc59668bd40b9f7ef5bce047d4a783eaae42de780b
$kokoroane voices/bm_fable.json kokoro-voices/bm_fable.json 757ddc02be15dc73f939a4c4f7d2642d3bd99d925c9360eac8533c356cf9f5bc
$kokoroane voices/bm_george.json kokoro-voices/bm_george.json 842150816a3503bdb97f9e0e96dd6dbbafc27eec5bb78957da48875cde398f10
$kokoroane voices/bm_lewis.json kokoro-voices/bm_lewis.json 94da3e86a7902696171195732c623f26f368086e3715a5fe6352ef3c557dfc84
EOF
}

sha() { shasum -a 256 "$1" | cut -c1-64; }

# Every file into the cache, checked. Fails on the first that cannot be had.
fetch() {
	files | while read -r pinned path into want; do
		dest="$cache/$into"
		[ -f "$dest" ] && [ "$(sha "$dest")" = "$want" ] && continue
		mkdir -p "$(dirname "$dest")"
		url="https://huggingface.co/${pinned%@*}/resolve/${pinned#*@}/$path"
		curl -fsSL --retry 3 -o "$dest.part" "$url" || { rm -f "$dest.part"; echo "voice-models.sh: could not fetch $url" >&2; return 1; }
		got=$(sha "$dest.part")
		if [ "$got" != "$want" ]; then
			rm -f "$dest.part"
			echo "voice-models.sh: $path is $got, not $want" >&2
			return 1
		fi
		mv "$dest.part" "$dest"
	done
}

if ! fetch; then
	if [ "${1:-}" = --carry ] && [ "${CONFIGURATION:-Debug}" = Debug ]; then
		echo "warning: voice-models.sh: no voice in this build; voice mode will say so" >&2
		exit 0
	fi
	echo "error: voice-models.sh: the voice could not be fetched" >&2
	exit 1
fi

# Each JSON voice as the .bin beside af_heart.bin: rows 1 to 510 of 256 numbers, little-endian fp32.
for json in "$cache"/kokoro-voices/*.json; do
	bin="$cache/kokoro-82m-coreml/ANE/$(basename "$json" .json).bin"
	[ -f "$bin" ] && [ "$bin" -nt "$json" ] && continue
	/usr/bin/python3 -c 'import json, struct, sys
rows = json.load(open(sys.argv[1]))
open(sys.argv[2], "wb").write(b"".join(struct.pack("<256f", *rows[str(r)]) for r in range(1, 511)))' "$json" "$bin.part"
	mv "$bin.part" "$bin"
done

if [ "${1:-}" = --carry ]; then
	voice="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Voice"
	mkdir -p "$voice"
	rm -rf "$voice/paradee-8m-coreml"
	for folder in kokoro-82m-coreml kokoro; do
		rsync -a --delete "$cache/$folder/" "$voice/$folder/"
	done
fi
