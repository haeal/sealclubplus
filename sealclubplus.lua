--[[
* track cooldowns for gathering beastman/kindred seals
--]]

addon.author    = 'samsonffxi, haeal';
addon.version   = '1.2.0';
addon.desc      = 'Seal farming with ready sound alerts.';
addon.link      = 'https://github.com/haeal/sealclubplus';
addon.name      = 'sealclubplus';
addon.commands  = {'/sealclubplus'};

require('common');
local chat      = require('chat');
local d3d       = require('d3d8');
local ffi       = require('ffi');
local fonts     = require('fonts');
local imgui     = require('imgui');
local prims     = require('primitives');
local scaling   = require('scaling');
local settings  = require('settings');

local C = ffi.C;
local d3d8dev = d3d.get_device();

-- Default Settings
local default_settings = T{
    visible = T{ true, },
    opacity = T{ 1.0, },
    padding = T{ 1.0, },
    scale = T{ 1.0, },
    font_scale = T{ 1.0 },
    x = T{ 100, },
    y = T{ 100, },

	seal_timer_ready_color = {0.0, 1.0, 0.0, 1.0}, --green
	seal_timer_warn_color = {1.0, 0.0, 0.0, 1.0}, --red
	bseal_cooldown = 300,
    kseal_cooldown = 900,
    shared_beastman_timer = T{ false, },
    kill_detect_text = T{ true, },
    kill_detect_packet = T{ true, },
    kill_detect_exp = T{ false, },
    sound_enabled = T{ true, },
    sound_file = 'water_tink.wav',
};

-- Variables
local sealclub = T{
    settings = settings.load(default_settings),

    -- screen movement variables..
    move = T{
        dragging = false,
        drag_x = 0,
        drag_y = 0,
        shift_down = false,
    },

    -- Editor variables..
    editor = T{
        is_open = T{ false, },
    },

    sealclub_start = ashita.time.clock()['ms'],

	last_bseal = 0,
	last_kseal = 0,

	bseal_timer = 0,
	kseal_timer = 0,

	bseal_count = 0,
	kseal_count = 0,
    seals_clubbed = 0,

    bseal_notified = true,
    kseal_notified = true,
    last_unspecified_kill = 0,
    last_counted_kill = 0,
    recent_kill_targets = T{ },

    myname = '',
};

local KILL_DEDUPE_WINDOW = 1.5;
local TARGET_KILL_MEMORY_WINDOW = 10.0;

local function get_sound_files()
    return T(ashita.fs.get_dir(addon.path:append('\\sounds\\'), '.*.wav', true) or { });
end

local function ensure_selected_sound(sound_files)
    if (type(sealclub.settings.sound_file) ~= 'string') then
        sealclub.settings.sound_file = '';
    end

    if (#sound_files == 0) then
        sealclub.settings.sound_file = '';
        return;
    end

    for _, sound_file in ipairs(sound_files) do
        if (sound_file:lower() == sealclub.settings.sound_file:lower()) then
            return;
        end
    end

    sealclub.settings.sound_file = sound_files[1];
end

local function play_ready_sound()
    if (not sealclub.settings.sound_enabled[1]) then
        return;
    end

    local sound_file = sealclub.settings.sound_file;
    if (type(sound_file) ~= 'string' or sound_file == '') then
        return;
    end

    ashita.misc.play_sound(addon.path:append('\\sounds\\'):append(sound_file));
end

local function play_selected_sound_preview()
    local sound_file = sealclub.settings.sound_file;
    if (type(sound_file) ~= 'string' or sound_file == '') then
        return;
    end

    ashita.misc.play_sound(addon.path:append('\\sounds\\'):append(sound_file));
end

local function prune_recent_kills(now)
    for target_id, kill_time in pairs(sealclub.recent_kill_targets) do
        if ((now - kill_time) > TARGET_KILL_MEMORY_WINDOW) then
            sealclub.recent_kill_targets[target_id] = nil;
        end
    end

    if (sealclub.last_unspecified_kill > 0 and (now - sealclub.last_unspecified_kill) > KILL_DEDUPE_WINDOW) then
        sealclub.last_unspecified_kill = 0;
    end
end

local function register_kill_for_target(target_id)
    local now = os.clock();
    prune_recent_kills(now);

    if (target_id ~= nil and target_id > 0) then
        local last_target_kill = sealclub.recent_kill_targets[target_id];
        if (last_target_kill ~= nil and (now - last_target_kill) < TARGET_KILL_MEMORY_WINDOW) then
            return false;
        end

        if (sealclub.last_unspecified_kill > 0 and (now - sealclub.last_unspecified_kill) < KILL_DEDUPE_WINDOW) then
            sealclub.recent_kill_targets[target_id] = sealclub.last_unspecified_kill;
            sealclub.last_unspecified_kill = 0;
            return false;
        end

        sealclub.recent_kill_targets[target_id] = now;
    end

    sealclub.seals_clubbed = sealclub.seals_clubbed + 1;
    sealclub.last_counted_kill = now;
    return true;
end

local function register_text_kill()
    local now = os.clock();
    prune_recent_kills(now);

    if ((sealclub.settings.kill_detect_packet[1] or sealclub.settings.kill_detect_exp[1]) and sealclub.last_counted_kill > 0 and (now - sealclub.last_counted_kill) < KILL_DEDUPE_WINDOW) then
        return false;
    end

    sealclub.seals_clubbed = sealclub.seals_clubbed + 1;
    sealclub.last_unspecified_kill = now;
    sealclub.last_counted_kill = now;
    return true;
end

local function get_local_player_and_pet_ids()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local player_id = party:GetMemberServerId(0);
    local player_index = party:GetMemberTargetIndex(0);
    local pet_index = entity:GetPetTargetIndex(player_index);
    local pet_id = 0;

    if (pet_index ~= nil and pet_index > 0) then
        pet_id = entity:GetServerId(pet_index);
    end

    return player_id, pet_id;
end

local function is_local_player_or_pet_actor(actor_id)
    local player_id, pet_id = get_local_player_and_pet_ids();
    return (actor_id ~= 0 and (actor_id == player_id or actor_id == pet_id));
end

local function is_reward_kill_message(message_id)
    return T{ 8, 50, 105, 253, 368, 371, 372, 718, 719, 735 }:contains(message_id);
end

--[[
* Renders the SealClubbing settings editor.
--]]
local function render_editor()
    if (not sealclub.editor.is_open[1]) then
        return;
    end

    imgui.SetNextWindowSize({ 580, 600, });
    imgui.SetNextWindowSizeConstraints({ 560, 600, }, { FLT_MAX, FLT_MAX, });
    if (imgui.Begin('SealClubPlus##Config', sealclub.editor.is_open)) then

        -- imgui.SameLine();
        if (imgui.Button('Save Settings')) then
            settings.save();
            print(chat.header(addon.name):append(chat.message('Settings saved.')));
        end
        imgui.SameLine();
        if (imgui.Button('Reload Settings')) then
            settings.reload();
            print(chat.header(addon.name):append(chat.message('Settings reloaded.')));
        end
        imgui.SameLine();
        if (imgui.Button('Reset Settings')) then
            settings.reset();
            print(chat.header(addon.name):append(chat.message('Settings reset to defaults.')));
        end
    end
    render_general_config_plus(settings);
    imgui.End();
end

function render_general_config_plus(settings)
    local sound_files = get_sound_files();
    ensure_selected_sound(sound_files);

    imgui.Text('General Settings');
    imgui.BeginChild('settings_general_plus', { 0, 360, }, true);
        imgui.ShowHelp('Toggles if SealClubPlus is visible or not.');
        imgui.SliderFloat('Opacity', sealclub.settings.opacity, 0.125, 1.0, '%.3f');
        imgui.ShowHelp('The opacity of the SealClubPlus window.');
        imgui.SliderFloat('Font Scale', sealclub.settings.font_scale, 0.1, 2.0, '%.3f');
        imgui.ShowHelp('The scaling of the font size.');

        local pos = { sealclub.settings.x[1], sealclub.settings.y[1] };
        if (imgui.InputInt2('Position', pos)) then
            sealclub.settings.x[1] = pos[1];
            sealclub.settings.y[1] = pos[2];
        end
        imgui.ShowHelp('The position of SealClubPlus on screen.');

        imgui.Checkbox('Use Shared Beastman Timer', sealclub.settings.shared_beastman_timer);
        imgui.ShowHelp('When enabled, any Beastman or Kindred seal drop starts both timers using the Beastman seal cooldown.');

        imgui.Text('Kill Detection');
        imgui.Checkbox('Use Chat Defeat Text', sealclub.settings.kill_detect_text);
        imgui.ShowHelp('Counts kills from the chat log defeat line. This may miss kills where your pet gets the killing blow.');
        imgui.Checkbox('Use Kill Message Packet', sealclub.settings.kill_detect_packet);
        imgui.ShowHelp('Counts kills from incoming action message packet 0x029. Supports local-player and local-pet killing blows.');
        imgui.Checkbox('Use Reward Packet', sealclub.settings.kill_detect_exp);
        imgui.ShowHelp('Counts kills from incoming reward packet 0x02D when the local player receives XP, limit, merit, or capacity rewards.');

        imgui.Checkbox('Enable Ready Sound', sealclub.settings.sound_enabled);
        imgui.ShowHelp('Plays a short sound when a Beastman or Kindred seal timer becomes ready.');

        if (#sound_files == 0) then
            imgui.TextColored({ 1.0, 0.8, 0.2, 1.0 }, 'No .wav files found in the sounds folder.');
        else
            local combo_width = 360;

            imgui.PushItemWidth(combo_width);
            if (imgui.BeginCombo('Ready Sound', sealclub.settings.sound_file)) then
                for _, sound_file in ipairs(sound_files) do
                    local is_selected = (sound_file == sealclub.settings.sound_file);
                    if (imgui.Selectable(sound_file, is_selected) and not is_selected) then
                        sealclub.settings.sound_file = sound_file;
                    end
                    if (is_selected) then
                        imgui.SetItemDefaultFocus();
                    end
                end
                imgui.EndCombo();
            end
            imgui.PopItemWidth();

            if (imgui.Button('Play Selected Sound##ready_sound_preview')) then
                play_selected_sound_preview();
            end
            imgui.ShowHelp('Plays the currently selected ready sound immediately for preview.');

            if (not sealclub.settings.sound_enabled[1]) then
                imgui.TextColored({ 1.0, 0.8, 0.2, 1.0 }, 'Ready sound is currently disabled, but preview still works.');
            end
        end
        imgui.ShowHelp('Selects a .wav file from the sealclubplus sounds folder.');

    imgui.EndChild();
end

function split_plus(inputstr, sep)
    if sep == nil then
        sep = '%s';
    end
    local t = {};
    for str in string.gmatch(inputstr, '([^'..sep..']+)') do
        table.insert(t, str);
    end
    return t;
end

----------------------------------------------------------------------------------------------------
-- Format numbers with commas
-- https://stackoverflow.com/questions/10989788/format-integer-in-lua
----------------------------------------------------------------------------------------------------
function format_int_plus(number)
    if (string.len(number) < 4) then
        return number
    end
    if (number ~= nil and number ~= '' and type(number) == 'number') then
        local i, j, minus, int, fraction = tostring(number):find('([-]?)(%d+)([.]?%d*)');

        -- we sometimes get a nil int from the above tostring, just return number in those cases
        if (int == nil) then
            return number
        end

        -- reverse the int-string and append a comma to all blocks of 3 digits
        int = int:reverse():gsub("(%d%d%d)", "%1,");
  
        -- reverse the int-string back remove an optional comma and put the 
        -- optional minus and fractional part back
        return minus .. int:reverse():gsub("^,", "") .. fraction;
    else
        return 'NaN';
    end
end

function clear_rewards_plus()
    sealclub.last_kseal = ashita.time.clock()['ms'];
    sealclub.last_bseal = ashita.time.clock()['ms'];
    sealclub.settings.first_attempt = 0;
    sealclub.settings.rewards = { };
    sealclub.settings.item_count = 0;
	sealclub.settings.bucket_count = 0;
end

----------------------------------------------------------------------------------------------------
-- Helper functions borrowed from luashitacast
----------------------------------------------------------------------------------------------------
function GetTimestampPlus()
    local pVanaTime = ashita.memory.find('FFXiMain.dll', 0, 'B0015EC390518B4C24088D4424005068', 0, 0);
    local pointer = ashita.memory.read_uint32(pVanaTime + 0x34);
    local rawTime = ashita.memory.read_uint32(pointer + 0x0C) + 92514960;
    local timestamp = {};
    timestamp.day = math.floor(rawTime / 3456);
    timestamp.hour = math.floor(rawTime / 144) % 24;
    timestamp.minute = math.floor((rawTime % 144) / 2.4);
    return timestamp;
end

--[[
* Registers a callback for the settings to monitor for character switches.
--]]
settings.register('settings', 'sealclubplus_settings_update', function (s)
    if (s ~= nil) then
        sealclub.settings = s;
    end

    -- Save the current settings..
    settings.save();
end);

--[[
* event: load
* desc : Event called when the addon is being loaded.
--]]
ashita.events.register('load', 'sealclubplus_load_cb', function ()
	sealclub.myname = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
end);

--[[
* event: unload
* desc : Event called when the addon is being unloaded.
--]]
ashita.events.register('unload', 'sealclubplus_unload_cb', function ()
    -- Save the current settings..
    settings.save();
end);

--[[
* event: command
* desc : Event called when the addon is processing a command.
--]]
ashita.events.register('command', 'sealclubplus_command_cb', function (e)
    -- Parse the command arguments..
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/sealclubplus')) then
        return;
    end

    -- Block all related commands..
    e.blocked = true;

    -- Handle: /sealclubplus - Toggles the sealclubplus editor.
    -- Handle: /sealclubplus edit - Toggles the sealclubplus editor.
    if (#args == 1 or (#args >= 2 and args[2]:any('edit'))) then
        sealclub.editor.is_open[1] = not sealclub.editor.is_open[1];
        return;
    end

    -- Handle: /sealclubplus save - Saves the current settings.
    if (#args >= 2 and args[2]:any('save')) then
        settings.save();
        print(chat.header(addon.name):append(chat.message('Settings saved.')));
        return;
    end

    -- Handle: /sealclubplus reload - Reloads the current settings from disk.
    if (#args >= 2 and args[2]:any('reload')) then
        settings.reload();
        print(chat.header(addon.name):append(chat.message('Settings reloaded.')));
        return;
    end

    -- Handle: /sealclubplus show - Shows the sealclubplus object.
    if (#args >= 2 and args[2]:any('show')) then
		-- reset last dig on show command to reset timeout counter
		sealclub.settings.visible[1] = true;
        return;
    end

    -- Handle: /sealclubplus hide - Hides the sealclubplus object.
    if (#args >= 2 and args[2]:any('hide')) then
		sealclub.settings.visible[1] = false;
        return;
    end
	
end);

--[[
* event: packet_in
* desc : Event called when the addon is processing incoming packets.
--]]
ashita.events.register('packet_in', 'sealclubplus_packet_in_cb', function (e)
    -- reset zone fatigue notification on zone
	if( e.id == 0x00B ) then 
        sealclub.last_kseal = 0;
        sealclub.last_bseal = 0;
        sealclub.kseal_notified = true;
        sealclub.bseal_notified = true;
        sealclub.last_unspecified_kill = 0;
        sealclub.last_counted_kill = 0;
        sealclub.recent_kill_targets = T{ };
    elseif (e.id == 0x029 and sealclub.settings.kill_detect_packet[1]) then
        local actor_id = struct.unpack('I', e.data_modified, 0x05);
        local target_id = struct.unpack('I', e.data_modified, 0x09);
        local message_id = struct.unpack('H', e.data_modified, 0x19);

        if (message_id == 6 and is_local_player_or_pet_actor(actor_id)) then
            register_kill_for_target(target_id);
        end
    elseif (e.id == 0x02D and sealclub.settings.kill_detect_exp[1]) then
        local player_id = struct.unpack('I', e.data_modified, 0x05);
        local target_id = struct.unpack('I', e.data_modified, 0x09);
        local reward_amount = struct.unpack('I', e.data_modified, 0x11);
        local message_id = struct.unpack('H', e.data_modified, 0x19) % 1024;
        local local_player_id = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);

        if (player_id == local_player_id and reward_amount > 0 and is_reward_kill_message(message_id)) then
            register_kill_for_target(target_id);
        end
    end
end);

----------------------------------------------------------------------------------------------------
-- watch for seal drops
----------------------------------------------------------------------------------------------------
ashita.events.register('text_in', 'sealclubplus_text_in_cb', function (e)
    local message = e.message;
    message = string.lower(message);
    message = string.strip_colors(message);

    local kseal = string.match(message, string.lower(sealclub.myname) .. " obtains a kindred's seal.");
    local bseal = string.match(message, string.lower(sealclub.myname) .. " obtains a beastmen's seal.");
	local kills = nil;
	if (sealclub.settings.kill_detect_text[1]) then
        kills = string.match(message, string.lower(sealclub.myname) .. " defeats the .");
    end
	
	-- Update last seal timestamp when obtained
	if (kseal) then
        sealclub.kseal_count = sealclub.kseal_count + 1;
		local seal_time = ashita.time.clock()['ms'];
		if (sealclub.settings.shared_beastman_timer[1]) then
            sealclub.last_kseal = seal_time;
            sealclub.last_bseal = seal_time;
            sealclub.kseal_notified = false;
            sealclub.bseal_notified = false;
        else
            sealclub.last_kseal = seal_time;
            sealclub.kseal_notified = false;
        end
	end
	if (bseal) then
        sealclub.bseal_count = sealclub.bseal_count + 1;
		local seal_time = ashita.time.clock()['ms'];
		if (sealclub.settings.shared_beastman_timer[1]) then
            sealclub.last_bseal = seal_time;
            sealclub.last_kseal = seal_time;
            sealclub.bseal_notified = false;
            sealclub.kseal_notified = false;
        else
            sealclub.last_bseal = seal_time;
            sealclub.bseal_notified = false;
        end
	end
    if (kills) then
        register_text_kill();
    end
end);

--[[
* event: d3d_beginscene
* desc : Event called when the Direct3D device is beginning a scene.
--]]
ashita.events.register('d3d_beginscene', 'sealclubplus_beginscene_cb', function (isRenderingBackBuffer)
end);

--[[
* event: d3d_present
* desc : Event called when the Direct3D device is presenting a scene.
--]]
ashita.events.register('d3d_present', 'sealclubplus_present_cb', function ()
    -- local last_attempt_secs = (ashita.time.clock()['ms'] - sealclub.last_attempt) / 1000.0;
    render_editor();

    -- Hide the sealclub object if not visible..
    if (not sealclub.settings.visible[1]) then
        return;
    end

    -- Hide the sealclub object if Ashita is currently hiding font objects..
    if (not AshitaCore:GetFontManager():GetVisible()) then
        return;
    end

    imgui.SetNextWindowBgAlpha(sealclub.settings.opacity[1]);
    imgui.SetNextWindowSize({ -1, -1, }, ImGuiCond_Always);
    if (imgui.Begin('SealClubPlus##Display', sealclub.settings.visible[1], bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav))) then
		local elapsed_time = ashita.time.clock()['s'] - math.floor(sealclub.sealclub_start / 1000.0);
		local bseal_diff = ashita.time.clock()['s'] - math.floor(sealclub.last_bseal / 1000.0);
		local kseal_diff = ashita.time.clock()['s'] - math.floor(sealclub.last_kseal / 1000.0);
        local bseal_cooldown = sealclub.settings.bseal_cooldown;
        local kseal_cooldown = sealclub.settings.shared_beastman_timer[1] and sealclub.settings.bseal_cooldown or sealclub.settings.kseal_cooldown;
        if (bseal_diff < bseal_cooldown) then
            sealclub.bseal_timer = bseal_cooldown - bseal_diff;
        elseif (bseal_diff >= sealclub.settings.bseal_cooldown) then
            sealclub.bseal_timer = 0;
		end
        if (kseal_diff < kseal_cooldown) then
            sealclub.kseal_timer = kseal_cooldown - kseal_diff;
        elseif (kseal_diff >= kseal_cooldown) then
            sealclub.kseal_timer = 0;
		end

        local played_ready_sound = false;
        if (bseal_diff > 0 and sealclub.bseal_timer > 0) then
            sealclub.bseal_notified = false;
        elseif (sealclub.last_bseal > 0 and not sealclub.bseal_notified) then
            play_ready_sound();
            sealclub.bseal_notified = true;
            played_ready_sound = true;
        end

        if (kseal_diff > 0 and sealclub.kseal_timer > 0) then
            sealclub.kseal_notified = false;
        elseif (sealclub.last_kseal > 0 and not sealclub.kseal_notified) then
            if (not played_ready_sound) then
                play_ready_sound();
            end
            sealclub.kseal_notified = true;
        end
		
		local btimer_display = sealclub.bseal_timer;
		if (btimer_display <= 0) then
			btimer_display = "Beastman Seal Ready"
		end
		local ktimer_display = sealclub.kseal_timer;
		if (ktimer_display <= 0) then
			ktimer_display = "Kindred Seal Ready"
		end

		imgui.SetWindowFontScale(sealclub.settings.font_scale[1] + 0.1);
        imgui.Text('    %%%  Seal Clubbing Plus  %%%');
		imgui.SetWindowFontScale(sealclub.settings.font_scale[1]);
		imgui.Separator();
		
		imgui.Text('BSeal Timer: ');
		imgui.SameLine();
		if (btimer_display == 'Beastman Seal Ready') then
			imgui.TextColored(sealclub.settings.seal_timer_ready_color, tostring(btimer_display));
		else
			imgui.Text(tostring(btimer_display));
		end
        imgui.Text('Beastman Seal Count: ');
        imgui.SameLine();
		imgui.Text(tostring(sealclub.bseal_count));
		imgui.Separator();

		imgui.Text('KSeal Timer: ');
		imgui.SameLine();
		if (ktimer_display == 'Kindred Seal Ready') then
			imgui.TextColored(sealclub.settings.seal_timer_ready_color, tostring(ktimer_display));
		else
			imgui.Text(tostring(ktimer_display));
		end
        imgui.Text('Kindred Seal Count: ');
        imgui.SameLine();
		imgui.Text(tostring(sealclub.kseal_count));
		imgui.Separator();
		
        imgui.Text('Total Time: ');
        imgui.SameLine();
        imgui.Text(tostring(string.format('%.2f', (elapsed_time / 60)) .. ' minutes'));
        imgui.Text('Seals Clubbed: ');
        imgui.SameLine();
        imgui.Text(tostring(format_int_plus(sealclub.seals_clubbed)) .. ' baby seals (x.x)');
    end
    imgui.End();

end);

--[[
* event: key
* desc : Event called when the addon is processing keyboard input. (WNDPROC)
--]]
ashita.events.register('key', 'sealclubplus_key_callback', function (e)
    -- Key: VK_SHIFT
    if (e.wparam == 0x10) then
        sealclub.move.shift_down = not (bit.band(e.lparam, bit.lshift(0x8000, 0x10)) == bit.lshift(0x8000, 0x10));
        return;
    end
end);

--[[
* event: mouse
* desc : Event called when the addon is processing mouse input. (WNDPROC)
--]]
ashita.events.register('mouse', 'sealclubplus_mouse_cb', function (e)
    -- Tests if the given coords are within the equipmon area.
    local function hit_test(x, y)
        local e_x = sealclub.settings.x[1];
        local e_y = sealclub.settings.y[1];
        local e_w = ((32 * sealclub.settings.scale[1]) * 4) + sealclub.settings.padding[1] * 3;
        local e_h = ((32 * sealclub.settings.scale[1]) * 4) + sealclub.settings.padding[1] * 3;

        return ((e_x <= x) and (e_x + e_w) >= x) and ((e_y <= y) and (e_y + e_h) >= y);
    end

    -- Returns if the equipmon object is being dragged.
    local function is_dragging() return sealclub.move.dragging; end

    -- Handle the various mouse messages..
    switch(e.message, {
        -- Event: Mouse Move
        [512] = (function ()
            sealclub.settings.x[1] = e.x - sealclub.move.drag_x;
            sealclub.settings.y[1] = e.y - sealclub.move.drag_y;

            e.blocked = true;
        end):cond(is_dragging),

        -- Event: Mouse Left Button Down
        [513] = (function ()
            if (sealclub.move.shift_down) then
                sealclub.move.dragging = true;
                sealclub.move.drag_x = e.x - sealclub.settings.x[1];
                sealclub.move.drag_y = e.y - sealclub.settings.y[1];

                e.blocked = true;
            end
        end):cond(hit_test:bindn(e.x, e.y)),

        -- Event: Mouse Left Button Up
        [514] = (function ()
            if (sealclub.move.dragging) then
                sealclub.move.dragging = false;

                e.blocked = true;
            end
        end):cond(is_dragging),

        -- Event: Mouse Wheel Scroll
        [522] = (function ()
            if (e.delta < 0) then
                sealclub.settings.opacity[1] = sealclub.settings.opacity[1] - 0.125;
            else
                sealclub.settings.opacity[1] = sealclub.settings.opacity[1] + 0.125;
            end
            sealclub.settings.opacity[1] = sealclub.settings.opacity[1]:clamp(0.125, 1);

            e.blocked = true;
        end):cond(hit_test:bindn(e.x, e.y)),
    });
end);