intesis-ac.fqa: main.lua md5.lua aes.lua pin.lua quickapp.json
	jq \
		--rawfile main main.lua \
		--rawfile md5 md5.lua \
		--rawfile aes aes.lua \
		--rawfile pin pin.lua \
		'.files[0].content = $$main | .files[1].content = $$md5 | .files[2].content = $$aes | .files[3].content = $$pin' quickapp.json > intesis-ac.fqa
