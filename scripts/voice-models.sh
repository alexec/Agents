#!/bin/sh
# The voice of voice mode (#2322): Paradee-8M int8 and the English front end it reads with
# (G2P and lexicon), about 23 MB, carried inside the Mac window and the Remote, so the app
# downloads nothing. Not in git: fetched from Hugging Face at a pinned revision, each file
# checked against its SHA-256 below, and kept in the build cache that every worktree shares.
#
#   scripts/voice-models.sh            fetch into the cache only
#   scripts/voice-models.sh --carry    an app's build: copy them into its Resources/Voice
#
# With no network and nothing in the cache, a Debug build goes on without the voice (voice
# mode says so); any other configuration fails, so no release ships without it.
set -eu

cache=${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}/voice
paradee=FluidInference/paradee-8m-coreml@bb38cf32d9b4ac06006be67797995b2dab0751f0
kokoro=FluidInference/kokoro-82m-coreml@e61d9ee79a01ad4ebf6b3d8bcfe2a03f6b8da105

# repo@revision, the file in the repository, where it goes under Voice/, its SHA-256.
files() {
	cat <<EOF
$paradee int8/ParadeeAcoustic.mlmodelc/analytics/coremldata.bin paradee-8m-coreml/int8/ParadeeAcoustic.mlmodelc/analytics/coremldata.bin 75b72dd0cf2b79be6a26670bdb0ea606f1c18129dbccc8a399b46f3b5f25ad36
$paradee int8/ParadeeAcoustic.mlmodelc/coremldata.bin paradee-8m-coreml/int8/ParadeeAcoustic.mlmodelc/coremldata.bin f721bdbe481f144947093a7839c6fdda91f30b05d7841873d129e1da9b0cd503
$paradee int8/ParadeeAcoustic.mlmodelc/model.mil paradee-8m-coreml/int8/ParadeeAcoustic.mlmodelc/model.mil aac7743af0e9a1a2621a9c0ea35f473630eb27eb2f86f76f53e0accc0fc81b2d
$paradee int8/ParadeeAcoustic.mlmodelc/weights/weight.bin paradee-8m-coreml/int8/ParadeeAcoustic.mlmodelc/weights/weight.bin 3b12e686efd35e6922148bbd131011391d078637fc38d4164b90a7007979004d
$paradee int8/ParadeeText.mlmodelc/analytics/coremldata.bin paradee-8m-coreml/int8/ParadeeText.mlmodelc/analytics/coremldata.bin 49b416543979b7b6c66acbd6109519ba911de9aa601bc04182e00f29b628dccf
$paradee int8/ParadeeText.mlmodelc/coremldata.bin paradee-8m-coreml/int8/ParadeeText.mlmodelc/coremldata.bin f31daa2542a0d519c9206e7973be437ad19810a4ffc417dc5d09fd58e523ce00
$paradee int8/ParadeeText.mlmodelc/model.mil paradee-8m-coreml/int8/ParadeeText.mlmodelc/model.mil 8464160a833505d949f71a02af2c3720eea0fcb36742ffa320489c1da4001ad3
$paradee int8/ParadeeText.mlmodelc/weights/weight.bin paradee-8m-coreml/int8/ParadeeText.mlmodelc/weights/weight.bin 48ecd9d62f60cb016c4542c4e15be47ab14059d433ad6ca456f4160491bcd2fc
$paradee int8/vocab.json paradee-8m-coreml/int8/vocab.json 3534d2a750475ae3df95830c11c00ffb4697622bf30622442aad0d603a456b68
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

if [ "${1:-}" = --carry ]; then
	voice="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Voice"
	mkdir -p "$voice"
	for folder in paradee-8m-coreml kokoro; do
		rsync -a --delete "$cache/$folder/" "$voice/$folder/"
	done
fi
