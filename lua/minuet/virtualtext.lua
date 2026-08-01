-- referenced from copilot.lua https://github.com/zbirenbaum/copilot.lua
local M = {}
local utils = require 'minuet.utils'
local api = vim.api
local uv = vim.uv or vim.loop

M.ns_id = api.nvim_create_namespace 'minuet.virtualtext'
M.augroup = api.nvim_create_augroup('MinuetVirtualText', { clear = true })

if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'MinuetVirtualText' })) then
    api.nvim_set_hl(0, 'MinuetVirtualText', { link = 'Comment' })
end

local internal = {
    augroup = M.augroup,
    ns_id = M.ns_id,
    extmark_id = 1,
    indicator_extmark_id = 2,

    timer = nil,
    indicator_timer = nil,
    context = {},
    is_on_throttle = false,
    current_completion_timestamp = 0,
}

local function should_auto_trigger()
    return vim.b.minuet_virtual_text_auto_trigger
end

local function completion_menu_visible()
    local has_cmp = pcall(require, 'cmp')
    local cmp_visible = false

    local has_blink = pcall(require, 'blink-cmp')
    local blink_visible = false

    if has_cmp then
        local ok, _cmp_visible = pcall(function()
            return require('cmp').core.view:visible()
        end)

        if ok then
            cmp_visible = _cmp_visible
        end
    end

    if has_blink then
        local ok, _blink_visible = pcall(function()
            return require('blink-cmp').is_visible()
        end)

        if ok then
            blink_visible = _blink_visible
        end
    end

    return vim.fn.pumvisible() == 1 or cmp_visible or blink_visible
end

---@param bufnr? integer
---@return minuet.VirtualtextSuggestionContext
local function get_ctx(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local ctx = internal.context[bufnr]
    if not ctx then
        ctx = {}
        internal.context[bufnr] = ctx
    end
    return ctx
end

---@return string[]?
local function get_last_typed_text(ctx)
    ctx = ctx or get_ctx()
    local last_typed = nil
    local last_pos = ctx.last_pos
    if not last_pos then
        return { '' }
    end

    local current_pos = api.nvim_win_get_cursor(0)

    -- Convert 1-based line to 0-based for nvim_buf_get_text
    local start_row = last_pos[1] - 1
    local start_col = last_pos[2]
    local end_row = current_pos[1] - 1
    local end_col = current_pos[2]

    if start_row < end_row or (start_row == end_row and start_col <= end_col) then
        last_typed = api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
    end

    return last_typed
end

---@class minuet.VirtualtextSuggestionContext
---@field suggestions? string[]
---@field choice? integer
---@field shown_choices? table<string, true>
---@field last_pos integer[]
---@field is_pending? boolean
---@field indicator_frame? integer

---@param ctx minuet.VirtualtextSuggestionContext
local function reset_ctx(ctx)
    ctx.suggestions = nil
    ctx.choice = nil
    ctx.shown_choices = nil
    ctx.last_pos = nil
    ctx.is_pending = nil
    ctx.indicator_frame = nil
end

local update_preview
local show_indicator_only
local get_current_suggestion

local function stop_timer()
    if internal.timer and not internal.timer:is_closing() then
        internal.timer:stop()
        internal.timer:close()
        internal.timer = nil
    end
end

local function stop_indicator()
    if internal.indicator_timer and not internal.indicator_timer:is_closing() then
        internal.indicator_timer:stop()
        internal.indicator_timer:close()
        internal.indicator_timer = nil
    end
end

local function get_indicator(ctx)
    if not ctx.is_pending then
        return ''
    end

    local indicator = require('minuet').config.virtualtext.request_indicator or {}
    if indicator.enabled == false then
        return ''
    end

    local frames = indicator.frames or {}
    if #frames == 0 then
        return ''
    end

    local frame = ctx.indicator_frame or 1
    return frames[((frame - 1) % #frames) + 1]
end

local function start_indicator(ctx)
    local indicator = require('minuet').config.virtualtext.request_indicator or {}
    if indicator.enabled == false then
        return
    end

    local frames = indicator.frames or {}
    if #frames == 0 then
        return
    end

    stop_indicator()
    ctx.indicator_frame = ctx.indicator_frame or 1
    internal.indicator_timer = vim.uv.new_timer()
    internal.indicator_timer:start(
        indicator.interval or 100,
        indicator.interval or 100,
        vim.schedule_wrap(function()
            if not ctx.is_pending then
                stop_indicator()
                return
            end

            ctx.indicator_frame = (ctx.indicator_frame or 1) + 1
            update_preview(ctx)
            if not get_current_suggestion(ctx) then
                show_indicator_only(ctx)
            end
        end)
    )
end

local function start_pending_indicator(ctx)
    ctx.is_pending = true
    ctx.indicator_frame = 1
    ctx.shown_choices = ctx.shown_choices or {}
    start_indicator(ctx)
    show_indicator_only(ctx)
end

local function clear_preview()
    api.nvim_buf_del_extmark(0, internal.ns_id, internal.extmark_id)
    api.nvim_buf_del_extmark(0, internal.ns_id, internal.indicator_extmark_id)
end

function show_indicator_only(ctx)
    local indicator = get_indicator(ctx)
    if indicator == '' then
        return
    end

    local cursor_col = vim.fn.col '.'
    local cursor_line = vim.fn.line '.'

    api.nvim_buf_set_extmark(0, internal.ns_id, cursor_line - 1, cursor_col - 1, {
        id = internal.indicator_extmark_id,
        virt_text = { { indicator, 'MinuetVirtualText' } },
        virt_text_pos = 'inline',
        hl_mode = 'replace',
    })

    ctx.last_pos = api.nvim_win_get_cursor(0)
end

---@param ctx? minuet.VirtualtextSuggestionContext
function get_current_suggestion(ctx)
    ctx = ctx or get_ctx()

    local ok, choice = pcall(function()
        if not vim.fn.mode():match '^[iR]' or not ctx.suggestions or #ctx.suggestions == 0 then
            return nil
        end

        local choice = ctx.suggestions[ctx.choice]

        return choice
    end)

    if ok then
        return choice
    end

    return nil
end

---@param ctx? minuet.VirtualtextSuggestionContext
function update_preview(ctx)
    ctx = ctx or get_ctx()

    local suggestion = get_current_suggestion(ctx)
    local indicator = get_indicator(ctx)
    local display_text = suggestion
    local display_lines = display_text and vim.split(display_text, '\n', { plain = true }) or {}

    clear_preview()

    local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

    if not display_text or #display_lines == 0 or (not show_on_completion_menu and completion_menu_visible()) then
        if indicator ~= '' then
            show_indicator_only(ctx)
        end
        return
    end

    api.nvim_buf_del_extmark(0, internal.ns_id, internal.indicator_extmark_id)

    local annot = ''

    if ctx.suggestions and #ctx.suggestions > 1 then
        annot = '(' .. ctx.choice .. '/' .. #ctx.suggestions .. ')'
    end

    if indicator ~= '' and suggestion and suggestion ~= '' then
        annot = (#annot > 0 and (annot .. ' ') or '') .. indicator
    end

    local cursor_col = vim.fn.col '.'
    local cursor_line = vim.fn.line '.'

    local extmark = {
        id = internal.extmark_id,
        virt_text = { { display_lines[1], 'MinuetVirtualText' } },
        virt_text_pos = 'inline',
    }

    if #display_lines > 1 then
        extmark.virt_lines = {}
        for i = 2, #display_lines do
            extmark.virt_lines[i - 1] = { { display_lines[i], 'MinuetVirtualText' } }
        end

        local last_line = #display_lines - 1
        extmark.virt_lines[last_line][1][1] = extmark.virt_lines[last_line][1][1] .. ' ' .. annot
    elseif #annot > 0 then
        extmark.virt_text[1][1] = extmark.virt_text[1][1] .. ' ' .. annot
    end

    extmark.hl_mode = 'replace'

    api.nvim_buf_set_extmark(0, internal.ns_id, cursor_line - 1, cursor_col - 1, extmark)

    if suggestion and ctx.shown_choices and not ctx.shown_choices[suggestion] then
        ctx.shown_choices[suggestion] = true
    end

    ctx.last_pos = api.nvim_win_get_cursor(0)
end

---@param ctx? minuet.VirtualtextSuggestionContext
local function cleanup(ctx)
    ctx = ctx or get_ctx()
    stop_timer()
    stop_indicator()
    reset_ctx(ctx)
    clear_preview()
end

---@param ctx minuet.VirtualtextSuggestionContext
---@return boolean Returns true if there are suggestions matching the user’s typed text; otherwise, false.
local function update_suggestion_on_typing(ctx)
    if not (ctx and ctx.suggestions and ctx.choice) then
        return false
    end

    local last_typed_text = get_last_typed_text()
    if not (last_typed_text and #last_typed_text > 0) then
        return false
    end

    local typed = table.concat(last_typed_text, '\n')
    if #typed == 0 or typed ~= ctx.suggestions[ctx.choice]:sub(1, #typed) then
        return false
    end

    for i, suggestion in ipairs(ctx.suggestions) do
        if suggestion:sub(1, #typed) == typed then
            ctx.suggestions[i] = suggestion:sub(#typed + 1, -1)
        else
            ctx.suggestions[i] = ''
        end
    end

    update_preview(ctx)
    stop_timer()
    return true
end

local function trigger(bufnr)
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return
    end

    utils.notify('Minuet virtual text started', 'verbose')

    local config = require('minuet').config

    local context = utils.get_context(utils.make_cmp_context())

    local provider = require('minuet.backends.' .. config.provider)
    local timestamp = uv.now()
    internal.current_completion_timestamp = timestamp

    local ctx = get_ctx()
    start_pending_indicator(ctx)

    local function apply_suggestions(data, is_partial)
        if timestamp ~= internal.current_completion_timestamp then
            if data and next(data) then
                local message = is_partial and 'Streaming completion items arrived, but too late, aborted'
                    or 'Completion items arrived, but too late, aborted'
                utils.notify(message, 'debug', 'info')
            end
            return
        end

        data = utils.list_dedup(data or {})
        local ctx = get_ctx()

        if not is_partial then
            ctx.is_pending = false
            stop_indicator()
        end

        if next(data) then
            local previous_choice = ctx.choice or 1
            ctx.suggestions = data
            ctx.choice = math.min(previous_choice, #data)
            ctx.shown_choices = ctx.shown_choices or {}
        end

        update_preview(ctx)
    end

    provider.complete(context, function(data)
        apply_suggestions(data, false)
    end, function(data)
        apply_suggestions(data, true)
    end)
end

local function advance(count, ctx)
    if ctx ~= get_ctx() then
        return
    end

    ctx.choice = (ctx.choice + count) % #ctx.suggestions
    if ctx.choice < 1 then
        ctx.choice = #ctx.suggestions
    end

    update_preview(ctx)
end

local function schedule()
    if internal.is_on_throttle then
        return
    end

    stop_timer()

    local config = require('minuet').config
    local bufnr = api.nvim_get_current_buf()

    internal.timer = vim.defer_fn(function()
        local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

        if
            internal.is_on_throttle
            or (not show_on_completion_menu and completion_menu_visible())
            or (not utils.run_hooks_until_failure(config.enable_predicates))
        then
            return
        end

        internal.is_on_throttle = true
        vim.defer_fn(function()
            internal.is_on_throttle = false
        end, config.throttle)

        start_pending_indicator(get_ctx(bufnr))
        trigger(bufnr)
    end, config.debounce)
end

local action = {}

action.next = function()
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        start_pending_indicator(ctx)
        trigger(api.nvim_get_current_buf())
        return
    end

    advance(1, ctx)
end

action.prev = function()
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        start_pending_indicator(ctx)
        trigger(api.nvim_get_current_buf())
        return
    end

    advance(-1, ctx)
end

---@param n_lines? integer Number of lines to accept from the suggestion. If nil, accepts all lines.
---Accepts the current suggestion by inserting it at the cursor position.
---If n_lines is provided, only the first n_lines of the suggestion are inserted.
---After insertion, moves the cursor to the end of the inserted text.
function action.accept(n_lines)
    local ctx = get_ctx()

    local suggestion = get_current_suggestion(ctx)
    if not suggestion then
        return
    end

    local suggestions = vim.split(suggestion, '\n')
    local remaining_suggestions = {}

    if n_lines then
        -- NOTE: If the first line is an empty string (""), it indicates that
        -- the original suggestion began with a newline character. This
        -- typically occurs during partial completion: when the user accepts
        -- the first line, the remaining suggestion may start with '\n'. In
        -- this scenario, we increment n_lines by 1 because the user intends to
        -- accept the next visible line of text, which corresponds to the
        -- subsequent element in the suggestions list.
        if suggestions[1] == '' then
            n_lines = n_lines + 1
        end
        n_lines = math.min(n_lines, #suggestions)
        remaining_suggestions = vim.list_slice(suggestions, n_lines + 1, #suggestions)
        suggestions = vim.list_slice(suggestions, 1, n_lines)
    end

    if #remaining_suggestions <= 0 then
        reset_ctx(ctx)
    end

    clear_preview()

    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]

    if vim.fn.pumvisible() == 1 then
        -- Accepting Minuet completion while the pum is open is temporary; when
        -- the user closes the pum, Vim restores the buffer state and removes
        -- Minuet's completion text. Therefore we need to close the pum before
        -- accepting.
        api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, true, true), 'n', true)
    end

    vim.schedule(function()
        api.nvim_buf_set_text(0, line, col, line, col, suggestions)
        local new_col = #suggestions[#suggestions]
        -- For single-line suggestions, adjust the column position by adding the
        -- current column offset
        if #suggestions == 1 then
            new_col = new_col + col
        end
        api.nvim_win_set_cursor(0, { line + #suggestions, new_col })
    end)
end

function action.accept_n_lines()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local n = vim.fn.input 'accept n lines: '

    -- FIXME: vim.fn.input may change cursor position, we need to restore the
    -- cursor position after the user input.

    vim.api.nvim_win_set_cursor(0, cursor_pos)

    ---@diagnostic disable-next-line:cast-local-type
    n = tonumber(n)
    if not n then
        return
    end
    if n > 0 then
        action.accept(n)
    else
        vim.notify('Invalid number of lines', vim.log.levels.ERROR)
    end
end

function action.accept_line()
    action.accept(1)
end

function action.dismiss()
    local ctx = get_ctx()
    cleanup(ctx)
end

function action.is_visible()
    return not not api.nvim_buf_get_extmark_by_id(0, internal.ns_id, internal.extmark_id, { details = false })[1]
end

function action.disable_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = false
    vim.notify('Minuet Virtual Text auto trigger disabled', vim.log.levels.INFO)
end

function action.enable_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = true
    vim.notify('Minuet Virtual Text auto trigger enabled', vim.log.levels.INFO)
end

function action.toggle_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = not should_auto_trigger()
    vim.notify(
        'Minuet Virtual Text auto trigger ' .. (should_auto_trigger() and 'enabled' or 'disabled'),
        vim.log.levels.INFO
    )
end

M.action = action

local autocmd = {}

function autocmd.on_insert_leave()
    cleanup()
end

function autocmd.on_buf_leave()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_leave()
    end
end

function autocmd.on_insert_enter()
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_buf_enter()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_enter()
    end
end

function autocmd.on_cursor_moved_i()
    local ctx = get_ctx()

    if update_suggestion_on_typing(ctx) then
        return
    end

    -- we don't cleanup immediately if the completion has arrived but not
    -- display yet.
    if ctx.shown_choices and next(ctx.shown_choices) then
        cleanup(ctx)
    end
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_cursor_hold_i()
    update_preview()
end

function autocmd.on_text_changed_p()
    autocmd.on_cursor_moved_i()
end

---@param info { buf: integer }
function autocmd.on_buf_unload(info)
    internal.context[info.buf] = nil
end

local function create_autocmds()
    api.nvim_create_autocmd('InsertLeave', {
        group = internal.augroup,
        callback = autocmd.on_insert_leave,
        desc = '[minuet.virtualtext] insert leave',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = internal.augroup,
        callback = autocmd.on_buf_leave,
        desc = '[minuet.virtualtext] buf leave',
    })

    api.nvim_create_autocmd('InsertEnter', {
        group = internal.augroup,
        callback = autocmd.on_insert_enter,
        desc = '[minuet.virtualtext] insert enter',
    })

    api.nvim_create_autocmd('BufEnter', {
        group = internal.augroup,
        callback = autocmd.on_buf_enter,
        desc = '[minuet.virtualtext] buf enter',
    })

    api.nvim_create_autocmd('CursorMovedI', {
        group = internal.augroup,
        callback = autocmd.on_cursor_moved_i,
        desc = '[minuet.virtualtext] cursor moved insert',
    })

    api.nvim_create_autocmd('TextChangedP', {
        group = internal.augroup,
        callback = autocmd.on_text_changed_p,
        desc = '[minuet.virtualtext] text changed p',
    })

    api.nvim_create_autocmd('BufUnload', {
        group = internal.augroup,
        callback = autocmd.on_buf_unload,
        desc = '[minuet.virtualtext] buf unload',
    })
end

local function set_keymaps(keymap)
    if keymap.accept then
        vim.keymap.set('i', keymap.accept, action.accept, {
            desc = '[minuet.virtualtext] accept suggestion',
            silent = true,
        })
    end

    if keymap.accept_line then
        vim.keymap.set('i', keymap.accept_line, action.accept_line, {
            desc = '[minuet.virtualtext] accept suggestion (line)',
            silent = true,
        })
    end

    if keymap.accept_n_lines then
        vim.keymap.set('i', keymap.accept_n_lines, action.accept_n_lines, {
            desc = '[minuet.virtualtext] accept suggestion (n lines)',
            silent = true,
        })
    end

    if keymap.next then
        vim.keymap.set('i', keymap.next, action.next, {
            desc = '[minuet.virtualtext] next suggestion',
            silent = true,
        })
    end

    if keymap.prev then
        vim.keymap.set('i', keymap.prev, action.prev, {
            desc = '[minuet.virtualtext] prev suggestion',
            silent = true,
        })
    end

    if keymap.dismiss then
        vim.keymap.set('i', keymap.dismiss, action.dismiss, {
            desc = '[minuet.virtualtext] dismiss suggestion',
            silent = true,
        })
    end
end

function M.setup()
    local config = require('minuet').config
    api.nvim_clear_autocmds { group = M.augroup }

    if #config.virtualtext.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.virtualtext.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(config.virtualtext.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.minuet_virtual_text_auto_trigger = true
                end
            end,
            group = M.augroup,
            desc = 'minuet virtual text filetype auto trigger',
        })
    end

    create_autocmds()
    set_keymaps(config.virtualtext.keymap)
end

return M
