obs           = obslua
source_name   = ""
title_source_name = ""
title_text    = ""
stopwatch_on  = false
start_time    = 0
elapsed_time  = 0
timer_id      = "stopwatch_timer"
hotkey_id_toggle = obs.OBS_INVALID_HOTKEY_ID
hotkey_id_reset  = obs.OBS_INVALID_HOTKEY_ID
is_updating   = false
script_settings_ref = nil

-- ソースの設定が変更された時にタイトルを同期する関数
function on_title_settings_update(calldata)
    if is_updating or stopwatch_on then return end

    local source = obs.calldata_source(calldata, "source")
    if source then
        local settings = obs.obs_source_get_settings(source)
        local new_text_from_source = obs.obs_data_get_string(settings, "text")
        obs.obs_data_release(settings)

        local new_text = new_text_from_source
        if title_source_name == source_name and source_name ~= "" then
            -- タイマー部分（例: " 00:00.0" や " 1:02:03.4"）を末尾から確実に除去
            -- %s+ は空白、[%d:]* は数字とコロンの繰り返し、%d%d:%d%d%.%d$ は分:秒.ミリ秒
            new_text = new_text_from_source:gsub("%s+[%d:]*%d%d:%d%d%.%d$", "")
        end

        if new_text ~= "" and new_text ~= title_text then -- 変更があり、かつ現在のタイトルと異なる場合のみ更新
            title_text = new_text
            if script_settings_ref ~= nil then
                obs.obs_data_set_string(script_settings_ref, "title_text", title_text)
            end
        end
    end
end

-- フォーマット関数: ミリ秒を 00:00.0 形式に変換
function format_time(ms)
    local total_seconds = math.floor(ms / 1000)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds % 60
    local deciseconds = math.floor((ms % 1000) / 100)
    return string.format("%02d:%02d.%d", minutes, seconds, deciseconds)
end

-- テキストソースの更新
function update_text()
    local source = obs.obs_get_source_by_name(source_name)
    if source ~= nil then
        local settings = obs.obs_data_create()
        local text = format_time(elapsed_time)
        if source_name == title_source_name and title_text ~= "" then
            text = title_text .. " " .. text
        end
        is_updating = true
        obs.obs_data_set_string(settings, "text", text)
        obs.obs_source_update(source, settings)
        is_updating = false
        obs.obs_data_release(settings)
        obs.obs_source_release(source)
    end
end

-- タイトルテキストの更新
function update_title_text()
    if title_source_name == source_name and source_name ~= "" then
        update_text() -- 同じソースならupdate_text側でまとめて処理
        return
    end

    local source = obs.obs_get_source_by_name(title_source_name)
    if source ~= nil then
        local settings = obs.obs_data_create()
        obs.obs_data_set_string(settings, "text", title_text)
        is_updating = true
        obs.obs_source_update(source, settings)
        is_updating = false
        obs.obs_data_release(settings)
        obs.obs_source_release(source)
    end
end

-- タイマーの実行
function timer_callback()
    local now = os.clock() * 1000
    elapsed_time = now - start_time
    update_text()
end

-- スタート/ストップ
function do_toggle()
    if stopwatch_on then
        obs.timer_remove(timer_callback)
        stopwatch_on = false
    else
        start_time = (os.clock() * 1000) - elapsed_time
        obs.timer_add(timer_callback, 100)
        stopwatch_on = true
    end
end

function do_reset()
    obs.timer_remove(timer_callback)
    stopwatch_on = false
    elapsed_time = 0
    update_text()
end

-- 各操作の入り口（ボタン・ホットキー共通）
function toggle_timer(props, p) do_toggle(); return true end
function reset_timer(props, p) do_reset(); return true end
function hotkey_toggle(pressed) if pressed then do_toggle() end end
function hotkey_reset(pressed) if pressed then do_reset() end end

-- スクリプトの設定画面
function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_text(props, "title_text", "タイトル文字", obs.OBS_TEXT_DEFAULT)

    -- ドロップダウンリストを「選択式」に変更し、初期値を設定
    local p = obs.obs_properties_add_list(props, "source", "タイマー表示ソース", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    local p_title = obs.obs_properties_add_list(props, "title_source", "タイトル表示ソース", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)

    obs.obs_property_list_add_string(p, "(ソースを選択してください)", "")
    obs.obs_property_list_add_string(p_title, "(ソースを選択してください)", "")

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local source_id = obs.obs_source_get_unversioned_id(source)
            if source_id == "text_gdiplus" or source_id == "text_ft2_source" then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(p, name, name)
                obs.obs_property_list_add_string(p_title, name, name)
            end
        end
    end
    obs.source_list_release(sources)

    obs.obs_properties_add_button(props, "start_stop", "スタート/ストップ", toggle_timer)
    obs.obs_properties_add_button(props, "reset", "リセット", reset_timer)

    return props
end

-- 設定更新時
function script_update(settings)
    if is_updating then return end
    script_settings_ref = settings
    local old_title_source = title_source_name
    source_name = obs.obs_data_get_string(settings, "source")
    title_source_name = obs.obs_data_get_string(settings, "title_source")
    title_text = obs.obs_data_get_string(settings, "title_text")

    -- ソースが変更された場合、信号の接続をやり直す
    if old_title_source ~= title_source_name then
        if old_title_source ~= "" then
            local source = obs.obs_get_source_by_name(old_title_source)
            if source then
                local sh = obs.obs_source_get_signal_handler(source)
                obs.signal_handler_disconnect(sh, "update", on_title_settings_update)
                obs.obs_source_release(source)
            end
        end
        local source = obs.obs_get_source_by_name(title_source_name)
        if source then
            local sh = obs.obs_source_get_signal_handler(source)
            obs.signal_handler_connect(sh, "update", on_title_settings_update)
            obs.obs_source_release(source)
        end
    end

    update_title_text()
end

-- ホットキーの登録と読み込み
function script_load(settings)
    script_settings_ref = settings
    -- 他の項目と混ざらないよう、明示的な名前でフロントエンドに登録
    hotkey_id_toggle = obs.obs_hotkey_register_frontend("stopwatch_toggle_key", "【スクリプト】ストップウォッチ：開始/停止", hotkey_toggle)
    hotkey_id_reset = obs.obs_hotkey_register_frontend("stopwatch_reset_key", "【スクリプト】ストップウォッチ：リセット", hotkey_reset)
    
    -- 初回の信号接続
    title_source_name = obs.obs_data_get_string(settings, "title_source")
    local source = obs.obs_get_source_by_name(title_source_name)
    if source then
        local sh = obs.obs_source_get_signal_handler(source)
        obs.signal_handler_connect(sh, "update", on_title_settings_update)
        obs.obs_source_release(source)
    end

    -- 保存されたホットキー設定を復元
    local a_toggle = obs.obs_data_get_array(settings, "stopwatch_toggle_hotkey")
    if a_toggle ~= nil then
        obs.obs_hotkey_load(hotkey_id_toggle, a_toggle)
        obs.obs_data_array_release(a_toggle)
    end

    local a_reset = obs.obs_data_get_array(settings, "stopwatch_reset_hotkey")
    if a_reset ~= nil then
        obs.obs_hotkey_load(hotkey_id_reset, a_reset)
        obs.obs_data_array_release(a_reset)
    end
end

function script_save(settings)
    -- 現在のホットキー設定を保存
    local a_toggle = obs.obs_hotkey_save(hotkey_id_toggle)
    obs.obs_data_set_array(settings, "stopwatch_toggle_hotkey", a_toggle)
    obs.obs_data_array_release(a_toggle)

    local a_reset = obs.obs_hotkey_save(hotkey_id_reset)
    obs.obs_data_set_array(settings, "stopwatch_reset_hotkey", a_reset)
    obs.obs_data_array_release(a_reset)
end

-- スクリプトの説明
function script_description()
    return "【設定方法】\n1. タイトル用とタイマー用のソース（テキストGDI+）を個別に用意します。\n2. 下のリストでそれぞれのソース名を選択してください。\n3. タイトルを入力すると指定したソースに反映されます。\n※「設定 > ホットキー」から、配信中もキー操作で開始/リセットが可能です。"
end