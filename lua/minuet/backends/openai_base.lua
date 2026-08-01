local M = {}
local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'

function M.openai_get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

function M.openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

local function decode_stream_lines(text)
    local result = {}
    local lines = vim.split(text or '', '\n', { plain = true, trimempty = false })

    for _, line in ipairs(lines) do
        line = line:gsub('\r$', ''):gsub('^data:%s*', '')
        if line == '' or line == '[DONE]' then
            goto continue
        end

        local ok, json = pcall(vim.json.decode, line)
        if not ok or not json.choices then
            goto continue
        end

        for _, choice in ipairs(json.choices) do
            local delta = choice.delta and choice.delta.content
            if type(delta) == 'string' and delta ~= '' then
                table.insert(result, { index = choice.index or 0, text = delta })
            end
        end

        ::continue::
    end

    return result
end

local function make_stream_parser(on_delta)
    local pending = ''

    local function decode(text)
        for _, delta in ipairs(decode_stream_lines(text)) do
            on_delta(delta.index, delta.text)
        end
    end

    return {
        feed = function(chunk)
            pending = pending .. (chunk or '')

            local complete, rest = pending:match '^(.*\n)([^\n]*)$'
            if not complete then
                return
            end
            pending = rest
            decode(complete)
        end,
        flush = function()
            if pending ~= '' then
                decode(pending)
                pending = ''
            end
        end,
    }
end

local function prepare_chat_items(items_raw, context, provider_name)
    if not items_raw then
        return nil
    end

    local items = common.parse_completion_items(items_raw, provider_name)
    items = common.filter_context_sequences_in_items(items, context)
    items = utils.trim_completion_items(items)

    return items
end

local function prepare_indexed_chat_items(raw_by_index, context, provider_name)
    local items = {}
    local indexes = vim.tbl_keys(raw_by_index)
    table.sort(indexes)

    for _, index in ipairs(indexes) do
        local parsed = prepare_chat_items(raw_by_index[index], context, provider_name)
        vim.list_extend(items, parsed or {})
    end

    return items
end

local function prepare_fim_items(items, context)
    local filtered_items = common.filter_context_sequences_in_items(items, context)
    local non_empty_items = vim.tbl_filter(function(x)
        return type(x) == 'string' and x:find '%S' ~= nil
    end, filtered_items)
    return non_empty_items
end

function M.complete_openai_base(options, context, callback, on_partial)
    local config = require('minuet').config

    common.terminate_all_jobs()

    local ctx = utils.make_chat_llm_shot(context, options.chat_input)
    ctx = common.create_chat_messages_from_list(ctx)

    local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))

    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(few_shots, 1, { role = 'system', content = system })
    vim.list_extend(few_shots, ctx)

    local data = {
        model = options.model,
        messages = few_shots,
        stream = options.stream,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }
    local transformed_data = common.apply_transforms(options.transform, options.end_point, headers, data)

    local data_file = utils.make_tmp_file(transformed_data.body)

    if data_file == nil then
        return
    end

    local args = utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file)

    if options.stream and on_partial then
        table.insert(args, 1, '-N')
    end

    local provider_name = 'openai_compatible'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local stream_raw_by_index = {}
    local parse_stream_chunk

    if options.stream then
        parse_stream_chunk = make_stream_parser(function(index, text)
            stream_raw_by_index[index] = (stream_raw_by_index[index] or '') .. text
            if on_partial then
                local items = prepare_indexed_chat_items(stream_raw_by_index, context, options.name)
                if items and next(items) then
                    on_partial(items)
                end
            end
        end)
    end

    local new_job = common.start_job(config.curl_cmd, args, {
        on_stdout = parse_stream_chunk and function(_, data)
            parse_stream_chunk.feed(data)
        end or nil,
        on_exit = function(_, result)
            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                model = options.model,
                name = options.name,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local items_raw

            local items

            if parse_stream_chunk then
                parse_stream_chunk.flush()
            end

            if options.stream then
                -- Reuse the incrementally parsed stream buckets so multi-choice
                -- streaming responses remain separate completion candidates.
                os.remove(data_file)
                if not (result.code == 28 or result.code == 0) then
                    utils.notify(
                        string.format('Request failed with exit code %d', result.code),
                        'error',
                        vim.log.levels.ERROR
                    )
                else
                    items = prepare_indexed_chat_items(stream_raw_by_index, context, options.name)
                end
            else
                items_raw = utils.no_stream_decode(result, data_file, options.name, M.openai_get_text_fn_no_stream)
                items = prepare_chat_items(items_raw, context, options.name)
            end

            if not items then
                callback()
                return
            end

            callback(items)
        end,
        on_spawn_error = function()
            os.remove(data_file)
            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                model = options.model,
                name = options.name,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })
            callback()
        end,
    })

    if not new_job then
        return
    end

    utils.run_event('MinuetRequestStarted', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

function M.complete_openai_fim_base(options, get_text_fn, context, callback)
    local config = require('minuet').config

    common.terminate_all_jobs()

    local data = {}

    data.model = options.model
    data.stream = options.stream
    local context_before_cursor = context.lines_before
    local context_after_cursor = context.lines_after
    local opts = context.opts

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    data.prompt = options.template.prompt(context_before_cursor, context_after_cursor, opts)
    data.suffix = options.template.suffix and options.template.suffix(context_before_cursor, context_after_cursor, opts)
        or nil

    local end_point = options.end_point
    local headers = {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }

    local transformed_data = common.apply_transforms(options.transform, end_point, headers, data)

    local data_file = utils.make_tmp_file(transformed_data.body)

    if data_file == nil then
        return
    end

    local args = utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file)

    local items = {}
    local n_completions = config.n_completions

    local provider_name = 'openai_fim_compatible'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = n_completions,
        timestamp = timestamp,
    })

    for idx = 1, n_completions do
        local new_job = common.start_job(config.curl_cmd, args, {
            on_exit = function(_, out)
                utils.run_event('MinuetRequestFinished', {
                    provider = provider_name,
                    name = options.name,
                    model = options.model,
                    n_requests = n_completions,
                    request_idx = idx,
                    timestamp = timestamp,
                })

                local result

                if options.stream then
                    result = utils.stream_decode(out, data_file, options.name, get_text_fn)
                else
                    result = utils.no_stream_decode(out, data_file, options.name, get_text_fn)
                end

                if result then
                    table.insert(items, result)
                end

                callback(prepare_fim_items(items, context))
            end,
            on_spawn_error = function()
                os.remove(data_file)
                utils.run_event('MinuetRequestFinished', {
                    provider = provider_name,
                    name = options.name,
                    model = options.model,
                    n_requests = n_completions,
                    request_idx = idx,
                    timestamp = timestamp,
                })
                callback(prepare_fim_items(items, context))
            end,
        })

        if new_job then
            utils.run_event('MinuetRequestStarted', {
                provider = provider_name,
                name = options.name,
                model = options.model,
                n_requests = n_completions,
                request_idx = idx,
                timestamp = timestamp,
            })
        end
    end
end

return M
