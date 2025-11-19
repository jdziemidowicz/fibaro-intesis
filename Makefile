intesis-ac.fqa: main.lua quickapp.json
	jq --rawfile main main.lua '.files[0].content = $$main' quickapp.json > intesis-ac.fqa

