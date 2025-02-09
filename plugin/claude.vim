" File: plugin/claude.vim
" vim: sw=2 ts=2 et fdm=marker fdl=0 fdc=1

" ============================================================================
" Configuration variables {{{1
" ============================================================================

if !exists('g:claude_api_key')
  let g:claude_api_key = ''
endif

if !exists('g:claude_api_url')
  let g:claude_api_url = 'https://api.anthropic.com/v1/messages'
endif

if !exists('g:claude_model')
  let g:claude_model = 'claude-3-5-sonnet-20241022'
endif

if !exists('g:claude_use_bedrock')
  let g:claude_use_bedrock = 0
endif

if !exists('g:claude_bedrock_region')
  let g:claude_bedrock_region = 'us-west-2'
endif

if !exists('g:claude_bedrock_model_id')
  let g:claude_bedrock_model_id = 'anthropic.claude-3-5-sonnet-20241022-v2:0'
endif

if !exists('g:claude_token_usage_categories')
  let g:claude_token_usage_categories = [
        \["Input Tokens", "input_tokens", 3.0/1.0E6],
        \["Output Tokens", "output_tokens", 15.0/1.0E6],
        \["Cache Create Input Tokens", "cache_creation_input_tokens", 3.75/1.0E6 ],
        \["Cache Read Input Tokens", "cache_read_input_tokens", 0.3/1.0E6 ]
        \]
endif

if !exists('g:claude_aws_profile')
  let g:claude_aws_profile = ''
endif

if !exists('g:claude_only_send_marked_buffers')
  let g:claude_only_send_marked_buffers = 0
endif

if !exists('g:claude_map_implement')
  let g:claude_map_implement = '<leader>ci'
endif

if !exists('g:claude_map_open_chat')
  let g:claude_map_open_chat = '<leader>cc'
endif

if !exists('g:claude_map_send_chat_message')
  let g:claude_map_send_chat_message = '<C-]>'
endif

if !exists('g:claude_map_cancel_response')
  let g:claude_map_cancel_response = '<leader>cx'
endif

if !exists('g:claude_testing')
  let g:claude_testing = 0
endif

" ============================================================================
" Logging functions {{{1
" ============================================================================

function! s:GetLogBuffer()
  let l:bufname = 'Claude Debug Log'
  let l:bufnr = bufnr(l:bufname)
  if l:bufnr == -1
    "" Create new buffer if it doesn't exist
    execute 'silent! new ' . l:bufname
    setlocal buftype=nofile bufhidden=hide noswapfile
    let l:bufnr = bufnr('%')
    wincmd c  " Close the window but keep the buffer
  endif
  return l:bufnr
endfunction

function! s:LogMessage(msg)
  let l:bufnr = s:GetLogBuffer()
  let l:timestamp = strftime('%Y-%m-%d %H:%M:%S')
  call appendbufline(l:bufnr, '$', l:timestamp . ' | ' . a:msg)
endfunction



" ============================================================================
" Keybindings setup {{{1
" ============================================================================

function! s:SetupClaudeKeybindings()

  command! -range -nargs=1 ClaudeImplement <line1>,<line2>call s:ClaudeImplement(<line1>, <line2>, <q-args>)
  execute "vnoremap " . g:claude_map_implement . " :ClaudeImplement<Space>"

  command! ClaudeChat call s:OpenClaudeChat()
  execute "nnoremap " . g:claude_map_open_chat . " :ClaudeChat<CR>"

  command! ClaudeCancel call s:CancelClaudeResponse()
  execute "nnoremap " . g:claude_map_cancel_response . " :ClaudeCancel<CR>"
endfunction

augroup ClaudeKeybindings
  autocmd!
  autocmd VimEnter * call s:SetupClaudeKeybindings()
augroup END


" ============================================================================
" Load prompts from disk {{{1
" ============================================================================

let s:plugin_dir = expand('<sfile>:p:h')

function! s:ClaudeLoadPrompt(prompt_type)
  let l:prompts_file = s:plugin_dir . '/claude_' . a:prompt_type . '_prompt.md'
  return readfile(l:prompts_file)
endfunction

if !exists('g:claude_default_system_prompt')
  let g:claude_default_system_prompt = s:ClaudeLoadPrompt('system')
endif

" Add this near the top of the file, after other configuration variables
if !exists('g:claude_implement_prompt')
  let g:claude_implement_prompt = s:ClaudeLoadPrompt('implement')
endif


" ============================================================================
" Claude API {{{1
" ============================================================================

" {"role": "user", "content":"Hi"} -> {"role":"user", "content":[{"type":"text", "text": "hi"}]
function! s:InflateMessageContent(msg)
  let result=copy(a:msg)
  let content = get(result, "content",[])
  if type(content) == v:t_string
    let result.content = [{"type": "text", "text": content}]
  endif
  return result
endfunction

" returns modification timestamp or zero if no undo information exists
function! s:GetBufTimestamp(bufnr)
  return get(undotree(a:bufnr).entries,-1,{"time":0}).time
endfunction

function! s:DocumentContext(name,content)
  return join([
        \"<buffer>",
        \"<name>" . a:name . "</name>",
        \"<content>", 
        \a:content,
        \"</content>",
        \"</buffer>"
        \], "\n")
endfunction

function! s:ClaudeQueryInternal(messages, buffers, system_prompt, tools, stream_callback, final_callback) abort
  " Prepare the API request
  let l:data = {}
  let l:headers = []
  let l:url = ''

  " Construct messages with content objects
  let messages = map(a:messages, "s:InflateMessageContent(v:val)")

  let quiet_buffers = []
  let busy_buffers = []
  let cutoff_timestamp = localtime() - 120
  for b in a:buffers 
    let context = s:DocumentContext(b.name, b.contents)
    if b.lastmodified == 0 || b.lastmodified > cutoff_timestamp
      call add(quiet_buffers,context)
    else
      call add(busy_buffers,context)
    endif
  endfor

  let context_messages = []
  if !empty(quiet_buffers)
    let msg = {"type" : "text", "text": join(["<documents>"] + quiet_buffers + ["</documents>"],"\n"), "cache_control": {"type": "ephemeral"}}
    call add(context_messages, msg)
  endif

  if !empty(busy_buffers)
    let msg = {"type" : "text", "text": join(["<documents>"] + busy_buffers + ["</documents>"],"\n"), "cache_control": {"type": "ephemeral"}}
    call add(context_messages, msg)
  endif

  " And prepend content objects for the buffers
  let messages[0].content = context_messages + messages[0].content
  let messages[-1].content[-1].cache_control = {"type": "ephemeral"} 


  "FIXME - test bedrock using new context
  if g:claude_use_bedrock
    let l:python_script = s:plugin_dir . '/claude_bedrock_helper.py'
    let l:cmd = ['python3', l:python_script,
          \ '--region', g:claude_bedrock_region,
          \ '--model-id', g:claude_bedrock_model_id,
          \ '--messages', json_encode(messages),
          \ '--system-prompt', a:system_prompt]

    if !empty(g:claude_aws_profile)
      call extend(l:cmd, ['--profile', g:claude_aws_profile])
    endif

    if !empty(a:tools)
      call extend(l:cmd, ['--tools', json_encode(a:tools)])
    endif

    call s:LogMessage('AWS Bedrock request: ' . join(l:cmd, ' '))
  else
    let l:url = g:claude_api_url
    let l:data = {
      \ 'model': g:claude_model,
      \ 'max_tokens': 2048,
      \ 'messages': messages,
      \ 'stream': v:true
      \ }
    if !empty(a:system_prompt)
      let l:data['system'] = a:system_prompt
    endif
    if !empty(a:tools)
      let l:data['tools'] = a:tools
    endif
    call extend(l:headers, ['-H', 'Content-Type: application/json'])
    call extend(l:headers, ['-H', 'x-api-key: ' . g:claude_api_key])
    call extend(l:headers, ['-H', 'anthropic-version: 2023-06-01'])
    call extend(l:headers, ['-H', "anthropic-beta: prompt-caching-2024-07-31"])

    " Convert data to JSON
    let l:json_data = json_encode(l:data)
    let l:cmd = ['curl', '-s', '-N', '-X', 'POST']
    call extend(l:cmd, l:headers)
    call extend(l:cmd, ['-d', l:json_data, l:url])

   call s:LogMessage('Claude API request: ' . join(map(copy(l:cmd), {idx, val -> val =~ "^[A-Za-z0-9_/-]*$" ? val : shellescape(val)}), ' '))
  endif

  " Start the job
  if has('nvim')
    let l:job = jobstart(l:cmd, {
      \ 'on_stdout': function('s:HandleStreamOutputNvim', [a:stream_callback, a:final_callback]),
      \ 'on_stderr': function('s:HandleJobErrorNvim', [a:stream_callback, a:final_callback]),
      \ 'on_exit': function('s:HandleJobExitNvim', [a:stream_callback, a:final_callback])
      \ })
  else
    let l:job = job_start(l:cmd, {
      \ 'out_cb': function('s:HandleStreamOutput', [a:stream_callback, a:final_callback]),
      \ 'err_cb': function('s:HandleJobError', [a:stream_callback, a:final_callback]),
      \ 'exit_cb': function('s:HandleJobExit', [a:stream_callback, a:final_callback])
      \ })
  endif

  return l:job
endfunction

function! s:DisplayTokenUsageAndCost(input_usage, final_usage)
  let msg = ["Token usage -"]
  for cat in g:claude_token_usage_categories
    let label = cat[0]
    let key = cat[1]
    let price = cat[2]
    let usage = get(a:input_usage, key,0) + get(a:final_usage, key, 0)
    call add(msg, printf("%s: %d ($%.4f)", label, usage, usage * price))
  endfor
  echom join(msg, " ")
endfunction

function! s:HandleStreamOutput(stream_callback, final_callback, channel, msg)
  call s:LogMessage("Response Stream:" . a:msg)
  " Split the message into lines
  let l:lines = split(a:msg, "\n")
  for l:line in l:lines
    " Check if the line starts with 'data:'
    if l:line =~# '^data:'
      " Extract the JSON data
      let l:json_str = substitute(l:line, '^data:\s*', '', '')
      let l:response = json_decode(l:json_str)

      if l:response.type == 'content_block_start' && l:response.content_block.type == 'tool_use'
        let s:current_tool_call = {
              \ 'id': l:response.content_block.id,
              \ 'name': l:response.content_block.name,
              \ 'input': ''
              \ }
      elseif l:response.type == 'content_block_delta' && has_key(l:response.delta, 'type') && l:response.delta.type == 'input_json_delta'
        if exists('s:current_tool_call')
          let s:current_tool_call.input .= l:response.delta.partial_json
        endif
      elseif l:response.type == 'content_block_stop'
        if exists('s:current_tool_call')
          let l:tool_input = json_decode(s:current_tool_call.input)
          " XXX this is a bit weird layering violation, we should probably call the callback instead
          call s:AppendToolUse(s:current_tool_call.id, s:current_tool_call.name, l:tool_input)
          unlet s:current_tool_call
        endif
      elseif has_key(l:response, 'delta') && has_key(l:response.delta, 'text')
        let l:delta = l:response.delta.text
        call a:stream_callback(l:delta)
      elseif l:response.type == 'message_start' && has_key(l:response, 'message') && has_key(l:response.message, 'usage')
        let s:stored_input_usage = copy(l:response.message.usage)
      elseif l:response.type == 'message_delta' && has_key(l:response, 'usage')
        if !exists('s:stored_input_usage')
          let s:stored_input_usage = {}
        endif
        call s:DisplayTokenUsageAndCost(s:stored_input_usage, l:response.usage)
        unlet s:stored_input_usage
      elseif l:response.type != 'message_stop' && l:response.type != 'message_start' && l:response.type != 'content_block_start' && l:response.type != 'ping'
        call a:stream_callback('Unknown Claude protocol output: "' . l:line . "\"\n")
      endif
    elseif l:line ==# 'event: ping'
      " Ignore ping events
    elseif l:line ==# 'event: error'
      call a:stream_callback('Error: Server sent an error event')
      call a:final_callback()
    elseif l:line ==# 'event: message_stop'
      call a:final_callback()
    elseif l:line !=# 'event: message_start' && l:line !=# 'event: message_delta' && l:line !=# 'event: content_block_start' && l:line !=# 'event: content_block_delta' && l:line !=# 'event: content_block_stop'
      call a:stream_callback('Unknown Claude protocol output: "' . l:line . "\"\n")
    endif
  endfor
endfunction

function! s:HandleJobError(stream_callback, final_callback, channel, msg)
  call a:stream_callback('Error: ' . a:msg)
  call a:final_callback()
endfunction

function! s:HandleJobExit(stream_callback, final_callback, job, status)
  call s:LogMessage('Job Exit with status: ' . a:status)
  if a:status != 0
    call a:stream_callback('Error: Job exited with status ' . a:status)
    call a:final_callback()
  endif
endfunction

function! s:HandleStreamOutputNvim(stream_callback, final_callback, job_id, data, event) dict
  for l:msg in a:data
    call s:HandleStreamOutput(a:stream_callback, a:final_callback, 0, l:msg)
  endfor
endfunction

function! s:HandleJobErrorNvim(stream_callback, final_callback, job_id, data, event) dict
  for l:msg in a:data
    if l:msg != ''
      call s:HandleJobError(a:stream_callback, a:final_callback, 0, l:msg)
    endif
  endfor
endfunction

function! s:HandleJobExitNvim(stream_callback, final_callback, job_id, exit_code, event) dict
  call s:HandleJobExit(a:stream_callback, a:final_callback, 0, a:exit_code)
endfunction


" ============================================================================
" Marked Buffers and Status Region {{{1
" ============================================================================

command! -bar -nargs=0 ClaudeOnlySendMarkedBuffers call s:ToggleOnlySendMarkedBuffers()
command! -bar -nargs=? ClaudeMarkBuffer call s:ToggleBuffer(s:int_buf(<args>))

function! s:ToggleOnlySendMarkedBuffers()
  let g:claude_only_send_marked_buffers = !g:claude_only_send_marked_buffers
  if g:claude_only_send_marked_buffers
    call s:UpdateStatusRegion([])
  else
    call s:UpdateStatusRegion()
  endif
  echo "Claude is now sending " .
  \ (g:claude_only_send_marked_buffers ? "ALL MARKED" : "ALL VISIBLE") .
  \ " buffers."
endfunction

" Toggle a buffer's inclusion, enabling the marked buffer mode if it's off
function! s:ToggleBuffer(bufnr) abort
  let l:bufnr = bufnr(a:bufnr)
  let [l:chat_bufnr, _, _] = s:GetOrCreateChatWindow()
  let g:claude_only_send_marked_buffers = 1
  let l:current_buffers = s:GetIncludedBuffers(l:chat_bufnr)

  let l:idx = index(l:current_buffers, l:bufnr)
  if l:idx >= 0
    call remove(l:current_buffers, l:idx)
    echo "Removed buffer" l:bufnr "from Claude chat"
  else
    call add(l:current_buffers, l:bufnr)
    echo "Added buffer" l:bufnr "to Claude chat"
  endif

  call s:RedrawStatusRegion(l:chat_bufnr, l:current_buffers)
endfunction

function! s:MarkBuffer(bufnr) abort
  if !g:claude_only_send_marked_buffers
    return
  endif
  let [l:chat_bufnr, _, _] = s:GetOrCreateChatWindow()
  let l:current_buffers = s:GetIncludedBuffers(l:chat_bufnr)
  call s:RedrawStatusRegion(l:chat_bufnr, s:dedupe(l:current_buffers + [a:bufnr]))
endfunction

" Update the status region with new buffer list
function! s:UpdateStatusRegion(buffers = v:null) abort
  let [l:bufnr, _, _] = s:GetOrCreateChatWindow()
  let l:buffers = a:buffers isnot v:null ? a:buffers : s:GetIncludedBuffers(l:bufnr)
  call s:RedrawStatusRegion(l:bufnr, l:buffers)
endfunction

function! s:RedrawStatusRegion(bufnr, buffers) abort
  let [l:start, l:end] = s:FindStatusRegion(a:bufnr)
  if !l:start | return | endif

  let l:message = ( g:claude_only_send_marked_buffers ?
    \ "Sending all marked." : "Sending all visible." ) .
    \ " Toggle with ClaudeOnlySendMarkedBuffers"
  call setbufline(a:bufnr, l:start, "Included buffers [". len(a:buffers) ."]: " . l:message)

  " Delete old list
  if l:end > l:start
    call deletebufline(a:bufnr, l:start + 1, l:end)
  endif

  " Add new list
  let l:lines = map(copy(a:buffers), {_, val -> "  ∙ " . val . " " . s:buf_displayname(val)})
  call appendbufline(a:bufnr, l:start, l:lines)
endfunction

" Find the status region in chat buffer, return [start_line, end_line] or [0,0]
function! s:FindStatusRegion(bufnr) abort
  let l:matches = matchbufline(a:bufnr, '^Included buffers \[[0-9]*]:', 1, '$')
  if empty(l:matches)
    return [0, 0]
  endif

  let l:start = l:matches[0].lnum
  let l:matches = matchbufline(a:bufnr, '^\S', l:start + 1, '$')
  let l:end = empty(l:matches) ? line('$') : l:matches[0].lnum - 1

  return [l:start, l:end]
endfunction

" Parse status region into list of buffer numbers
function! s:ParseIncludedBuffers(bufnr) abort
  let [l:start, l:end] = s:FindStatusRegion(a:bufnr)
  if !l:start || l:start == l:end | return [] | endif

  let l:matches = matchbufline(a:bufnr, '^  [-∙*] \?\zs\d\+\ze', l:start+1, l:end)
  let l:buffers = l:matches ->map({i, match -> str2nr(match.text)}) ->filter({i, buf -> bufloaded(buf)})
  return l:buffers
endfunction

function! s:GetIncludedBuffers(chat_bufnr)
  if g:claude_only_send_marked_buffers
    return s:ParseIncludedBuffers(a:chat_bufnr)
  else
    return s:VisibleIncludedBuffers(a:chat_bufnr)
  endif
endfunction

" Return all buffers visible in the same tab as bufnr
function! s:VisibleIncludedBuffers(chat_bufnr)
    let l:bufnr_tabs = getwininfo() ->filter({k,v -> v.bufnr==a:chat_bufnr}) ->map({k,v -> v.tabnr}) ->s:dedupe()
    let l:visible_buffers = l:bufnr_tabs ->map({i,t -> tabpagebuflist(t)}) ->flatten() ->s:dedupe()

    " Filter unlisted and Claude buffer
    let l:usable_buffers = l:visible_buffers ->filter({
    \   i,buf -> buf != a:chat_bufnr && buflisted(buf)
    \ })
    return l:usable_buffers
endfunction

function! s:dedupe(buffers)
  if len(a:buffers) == 0
    return a:buffers
  endif
  call sort(a:buffers,'n')
  " iterate backwards to preserve indices when deleting
  for i in range(len(a:buffers) - 1, 1, -1)
    if a:buffers[i] == a:buffers[i - 1]
      call remove(a:buffers, i)
    endif
  endfor
  return a:buffers
endfunction

" quoted buffer ID to string if numeric, preserve empty string
function! s:int_buf(buf='')
  return str2nr(a:buf) ? str2nr(a:buf) : a:buf
endfunction

" get name of buffer, but print special names for special buffers
function! s:buf_displayname(nr)
  let n = bufname(a:nr)
  return len(n) ? n : getbufvar(a:nr, '&buftype') == "nofile" ? "[Scratch]" : "[No Name]"
endfunction

" ============================================================================
" Diff View {{{1
" ============================================================================

function! s:ApplyChange(normal_command, content)
  let l:view = winsaveview()
  let l:paste_option = &paste

  set paste

  let l:normal_command = substitute(a:normal_command, '<CR>', "\<CR>", 'g')
  execute 'normal ' . l:normal_command . "\<C-r>=a:content\<CR>"

  let &paste = l:paste_option
  call winrestview(l:view)
endfunction

function! s:ApplyCodeChangesDiff(bufnr, changes)
  let l:original_winid = win_getid()
  let l:failed_edits = []

  " Find or create a window for the target buffer
  let l:target_winid = bufwinid(a:bufnr)
  if l:target_winid == -1
    " If the buffer isn't in any window, split and switch to it
    execute 'split'
    execute 'buffer ' . a:bufnr
    let l:target_winid = win_getid()
  else
    " Switch to the window containing the target buffer
    call win_gotoid(l:target_winid)
  endif

  " Create a new window for the diff view
  rightbelow vnew
  setlocal buftype=nofile
  let &filetype = getbufvar(a:bufnr, '&filetype')

  " Copy content from the target buffer
  call setline(1, getbufline(a:bufnr, 1, '$'))

  " Apply all changes
  for change in a:changes
    try
      if change.type == 'content'
        call s:ApplyChange(change.normal_command, change.content)
      elseif change.type == 'vimexec'
        for cmd in change.commands
          try
            execute 'normal ' . cmd
          catch
            execute cmd
          endtry
        endfor
      endif
    catch
      call add(l:failed_edits, change)
      echohl WarningMsg
      echomsg "Failed to apply edit in buffer " . bufname(a:bufnr) . ": " . v:exception
      echohl None
    endtry
  endfor

  " Set up diff for both windows
  diffthis
  call win_gotoid(l:target_winid)
  diffthis

  " Return to the original window
  call win_gotoid(l:original_winid)

  if !empty(l:failed_edits)
    echohl WarningMsg
    echomsg "Some edits could not be applied. Check the messages for details."
    echohl None
  endif
endfunction


" ============================================================================
" Tool Integration {{{1
" ============================================================================

if !exists('g:claude_tools')
  let g:claude_tools = [
    \ {
    \   'name': 'python',
    \   'description': 'Execute a Python one-liner code snippet and return the standard output. NEVER just print a constant or use Python to load the file whose buffer you already see. Use the tool only in cases where a Python program will generate a reliable, precise response than you cannot realistically produce on your own.',
    \   'input_schema': {
    \     'type': 'object',
    \     'properties': {
    \       'code': {
    \         'type': 'string',
    \         'description': 'The Python one-liner code to execute. Wrap the final expression in `print` to see its result - otherwise, output will be empty.'
    \       }
    \     },
    \     'required': ['code']
    \   }
    \ },
    \ {
    \   'name': 'shell',
    \   'description': 'Execute a shell command and return both stdout and stderr. Use with caution as it can potentially run harmful commands.',
    \   'input_schema': {
    \     'type': 'object',
    \     'properties': {
    \       'command': {
    \         'type': 'string',
    \         'description': 'The shell command or a short one-line script to execute.'
    \       }
    \     },
    \     'required': ['command']
    \   }
    \ },
    \ {
    \   "name": "open",
    \   "description": "Open an existing buffer (file, directory or netrw URL) so that you get access to its content. Returns the buffer name, or 'ERROR' for non-existent paths.",
    \   "input_schema": {
    \     "type": "object",
    \     "properties": {
    \       "path": {
    \         "type": "string",
    \         "description": "The path to open, passed as an argument to the vim :edit command"
    \       }
    \     },
    \     "required": ["path"]
    \   }
    \ },
    \ {
    \   "name": "new",
    \   "description": "Create a new file, opening a buffer for it so that edits can be applied. Returns an error if the file already exists.",
    \   "input_schema": {
    \     "type": "object",
    \     "properties": {
    \       "path": {
    \         "type": "string",
    \         "description": "The path of the new file to create, passed as an argument to the vim :new command"
    \       }
    \     },
    \     "required": ["path"]
    \   }
    \ },
    \ {
    \   'name': 'open_web',
    \   'description': 'Open a new buffer with the text content of a specific webpage. Use this for accessing documentation or other search results.',
    \   'input_schema': {
    \     'type': 'object',
    \     'properties': {
    \       'url': {
    \         'type': 'string',
    \         'description': 'The URL of the webpage to read'
    \       },
    \     },
    \     'required': ['url']
    \   }
    \ },
    \ {
    \   'name': 'web_search',
    \   'description': 'Perform a web search and return the top 5 results. Use this to find information beyond your knowledge on the web (e.g. about specific APIs, new tools or to troubleshoot errors). Strongly consider using open_web next to open one or several result URLs to learn more.',
    \   'input_schema': {
    \     'type': 'object',
    \     'properties': {
    \       'query': {
    \         'type': 'string',
    \         'description': 'The search query (bunch of keywords / keyphrases)'
    \       },
    \     },
    \     'required': ['query']
    \   }
    \ }
    \ ]
endif

function! s:ExecuteTool(tool_name, arguments)
  if a:tool_name == 'python'
    return s:ExecutePythonCode(a:arguments.code)
  elseif a:tool_name == 'shell'
    return s:ExecuteShellCommand(a:arguments.command)
  elseif a:tool_name == 'open'
    return s:ExecuteOpenTool(a:arguments.path)
  elseif a:tool_name == 'new'
    return s:ExecuteNewTool(a:arguments.path)
  elseif a:tool_name == 'open_web'
    return s:ExecuteOpenWebTool(a:arguments.url)
  elseif a:tool_name == 'web_search'
    let l:escaped_query = py3eval("''.join([c if c.isalnum() or c in '-._~' else '%{:02X}'.format(ord(c)) for c in vim.eval('a:arguments.query')])")
    return s:ExecuteOpenWebTool("https://www.google.com/search?q=" . l:escaped_query)
  else
    return 'Error: Unknown tool ' . a:tool_name
  endif
endfunction

function! s:ExecutePythonCode(code)
  call s:LogMessage('Python code execution request: ' . a:code)
  redraw
  let l:confirm = input("Execute this Python code? (y/n/C-C; if you C-C to stop now, you can C-] later to resume) ")
  if l:confirm =~? '^y'
    let l:result = system('python3 -c ' . shellescape(a:code))
    call s:LogMessage('Python output: ' . substitute(l:result, '\n', '\n                     | ', 'g'))
    return l:result
  else
    call s:LogMessage('Python execution cancelled by user')
    return "Python code execution cancelled by user."
  endif
endfunction

function! s:ExecuteShellCommand(command)
  call s:LogMessage('Shell command execution request: ' . a:command)
  redraw
  let l:confirm = input("Execute this shell command? (y/n/C-C; if you C-C to stop now, you can C-] later to resume) ")
  if l:confirm =~? '^y'
    let l:output = system(a:command)
    let l:exit_status = v:shell_error
    call s:LogMessage('Shell command output (status=' . l:exit_status . '): ' . substitute(l:output, '\n', '\n                     | ', 'g'))
    return l:output . "\nExit status: " . l:exit_status
  else
    call s:LogMessage('Shell command execution cancelled by user')
    return "Shell command execution cancelled by user."
  endif
endfunction

function! s:ExecuteOpenTool(path)
  let l:current_winid = win_getid()

  topleft 1new
  call s:MarkBuffer(bufnr())

  try
    execute 'edit ' . fnameescape(a:path)
    let l:bufname = bufname('%')

    if line('$') == 1 && getline(1) == ''
      close
      call win_gotoid(l:current_winid)
      return 'ERROR: The opened buffer was empty (non-existent?)'
    else
      call win_gotoid(l:current_winid)
      return l:bufname
    endif
  catch
    close
    call win_gotoid(l:current_winid)
    return 'ERROR: ' . v:exception
  endtry
endfunction

function! s:ExecuteNewTool(path)
  if filereadable(a:path)
    return 'ERROR: File already exists: ' . a:path
  endif

  let l:current_winid = win_getid()

  topleft 1new
  execute 'silent write ' . fnameescape(a:path)
  let l:bufname = bufname('%')
  call s:MarkBuffer(bufnr())

  call win_gotoid(l:current_winid)
  return l:bufname
endfunction

function! s:ExecuteOpenWebTool(url)
  let l:current_winid = win_getid()

  topleft 1new
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  call s:MarkBuffer(bufnr())

  execute ':r !elinks -dump ' . escape(shellescape(a:url), '%#!')
  if v:shell_error
    close
    call win_gotoid(l:current_winid)
    return 'ERROR: Failed to fetch content from ' . a:url . ': ' . v:shell_error
  endif

  let l:bufname = fnameescape(a:url)
  execute 'file ' . l:bufname

  call win_gotoid(l:current_winid)
  return l:bufname
endfunction


" ============================================================================
" ClaudeImplement {{{1
" ============================================================================

function! s:LogImplementInChat(instruction, implement_response, bufname, start_line, end_line)
  let [l:chat_bufnr, l:chat_winid, l:current_winid] = s:GetOrCreateChatWindow()

  let start_line_text = getline(a:start_line)
  let end_line_text = getline(a:end_line)

  if l:chat_winid != -1
    call win_gotoid(l:chat_winid)
    let l:indent = s:GetClaudeIndent()

    " Remove trailing "You:" line if it exists
    let l:last_line = line('$')
    if getline(l:last_line) =~ '^You:\s*$'
      execute l:last_line . 'delete _'
    endif

    call append('$', 'You: Implement in ' . a:bufname . ' (lines ' . a:start_line . '-' . a:end_line . '): ' . a:instruction)
    call append('$', l:indent . start_line_text)
    if a:end_line - a:start_line > 1
      call append('$', l:indent . "...")
    endif
    if a:end_line - a:start_line > 0
      call append('$', l:indent . end_line_text)
    endif
    call s:AppendResponse(a:implement_response)
    call s:ClosePreviousFold()
    call s:CloseCurrentInteractionCodeBlocks()
    call s:PrepareNextInput()

    call win_gotoid(l:current_winid)
  endif
endfunction

" Function to implement code based on instructions
function! s:ClaudeImplement(line1, line2, instruction) range
  " Get the selected code
  let l:selected_code = join(getline(a:line1, a:line2), "\n")
  let l:bufnr = bufnr('%')
  let l:bufname = bufname('%')
  let l:winid = win_getid()

  " Prepare the prompt for code implementation
  let l:code_context = [{"name": "selected_code", "contents": l:selected_code, "lastmodified": 0}]
  let l:system_prompt = join(g:claude_implement_prompt, "\n")
  let l:tools = []

  " Query Claude
  let l:messages = [{'role': 'user', 'content': a:instruction}]
  call s:ClaudeQueryInternal(l:messages, l:code_context, l:system_prompt, l:tools,
        \ function('s:StreamingImplementResponse'),
        \ function('s:FinalImplementResponse', [a:line1, a:line2, l:bufnr, l:bufname, l:winid, a:instruction]))
endfunction

function! s:ExtractCodeFromMarkdown(markdown)
  let l:lines = split(a:markdown, "\n")
  let l:in_code_block = 0
  let l:code = []
  for l:line in l:lines
    if l:line =~ '^```'
      let l:in_code_block = !l:in_code_block
    elseif l:in_code_block
      call add(l:code, l:line)
    endif
  endfor
  return join(l:code, "\n")
endfunction

function! s:StreamingImplementResponse(delta)
  if !exists("s:implement_response")
    let s:implement_response = ""
  endif

  let s:implement_response .= a:delta
endfunction

function! s:FinalImplementResponse(line1, line2, bufnr, bufname, winid, instruction)
  call win_gotoid(a:winid)

  call s:LogImplementInChat(a:instruction, s:implement_response, a:bufname, a:line1, a:line2)

  let l:implemented_code = s:ExtractCodeFromMarkdown(s:implement_response)

  let l:changes = [{
    \ 'type': 'content',
    \ 'normal_command': a:line1 . 'GV' . a:line2 . 'Gc',
    \ 'content': l:implemented_code
    \ }]
  call s:ApplyCodeChangesDiff(a:bufnr, l:changes)

  echomsg "Apply diff, see :help diffget. Close diff buffer with :q."

  unlet s:implement_response
  unlet! s:current_chat_job
endfunction


" ============================================================================
" ClaudeChat: Chat service functions {{{1
" ============================================================================


function! s:GetOrCreateChatWindow()
  let l:chat_bufnr = bufnr('Claude Chat')
  if l:chat_bufnr == -1 || !bufloaded(l:chat_bufnr)
    call s:OpenClaudeChat()
    let l:chat_bufnr = bufnr('Claude Chat')
  endif

  let l:chat_winid = bufwinid(l:chat_bufnr)
  let l:current_winid = win_getid()

  return [l:chat_bufnr, l:chat_winid, l:current_winid]
endfunction

function! s:GetClaudeIndent()
  if &expandtab
    return repeat(' ', &shiftwidth)
  else
    return repeat("\t", (&shiftwidth + &tabstop - 1) / &tabstop)
  endif
endfunction

function! s:AppendResponse(response)
  let l:response_lines = split(a:response, "\n")
  if len(l:response_lines) == 1
    call append('$', 'Claude: ' . l:response_lines[0])
  else
    call append('$', 'Claude:')
    let l:indent = s:GetClaudeIndent()
    call append('$', map(l:response_lines, {_, v -> v =~ '^\s*$' ? '' : l:indent . v}))
  endif
endfunction


" ============================================================================
" Chat window UX {{{1
" ============================================================================

function! GetChatFold(lnum)
  let l:line = getline(a:lnum)
  let l:prev_level = foldlevel(a:lnum - 1)

  if l:line =~ '^You:' || l:line =~ '^System prompt:' || l:line =~ '^Included buffers \[[0-9]*]:'
    return '>1'  " Start a new fold at level 1
  elseif l:line =~ '^\s' || l:line =~ '^$' || l:line =~ '^.*:'
    if l:line =~ '^\s*```'
      if l:prev_level == 1
        return '>2'  " Start a new fold at level 2 for code blocks
      else
        return '<2'  " End the fold for code blocks
      endif
    else
      return '='   " Use the fold level of the previous line
    endif
  else
    return '0'  " Terminate the fold
  endif
endfunction

function! s:SetupClaudeChatSyntax()
  if exists("b:current_syntax")
    return
  endif

  syntax include @markdown syntax/markdown.vim

  syntax region claudeChatSystem start=/^System prompt:/ end=/^\S/me=s-1 contains=claudeChatSystemKeyword
  syntax region claudeChatTopStatus start=/^Included buffers \[[0-9]*]:/ end=/^\S/me=s-1 contains=claudeChatIncludedBuffersKeyword
  syntax match claudeChatSystemKeyword /^System prompt:/ contained
  syntax match claudeChatIncludedBuffersKeyword /^Included buffers \[[0-9]*]:/ contained
  syntax match claudeChatYou /^You:/
  syntax match claudeChatClaude /^Claude\.*:/
  syntax match claudeChatToolUse /^Tool use.*:/
  syntax match claudeChatToolResult /^Tool result.*:/
  syntax region claudeChatClaudeContent start=/^Claude.*:/ end=/^\S/me=s-1 contains=claudeChatClaude,@markdown,claudeChatCodeBlock
  syntax region claudeChatToolBlock start=/^Tool.*:/ end=/^\S/me=s-1 contains=claudeChatToolUse,claudeChatToolResult
  syntax region claudeChatCodeBlock start=/^\s*```/ end=/^\s*```/ contains=@NoSpell

  " Don't make everything a code block; FIXME this works satisfactorily
  " only for inline markdown pieces
  syntax clear markdownCodeBlock

  highlight default link claudeChatSystem Comment
  highlight default link claudeChatSystemKeyword Keyword
  highlight default link claudeChatTopStatus Comment
  highlight default link claudeChatIncludedBuffersKeyword Keyword
  highlight default link claudeChatYou Keyword
  highlight default link claudeChatClaude Keyword
  highlight default link claudeChatToolUse Keyword
  highlight default link claudeChatToolResult Keyword
  highlight default link claudeChatToolBlock Comment
  highlight default link claudeChatCodeBlock Comment

  let b:current_syntax = "claudechat"
endfunction

function! s:GoToLastYouLine()
  normal! G$
endfunction

function! s:OpenClaudeChat()
  let l:claude_bufnr = bufnr('Claude Chat')

  if l:claude_bufnr == -1 || !bufloaded(l:claude_bufnr)
    execute 'botright new Claude Chat'
    setlocal buftype=nofile
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal linebreak

    setlocal foldmethod=expr
    setlocal foldexpr=GetChatFold(v:lnum)
    setlocal foldlevel=1

    call s:SetupClaudeChatSyntax()

    call setline(1, ['Included buffers []: ' ])
    call append('$', ['System prompt: ' . g:claude_default_system_prompt[0]])
    call append('$', map(g:claude_default_system_prompt[1:], {_, v -> "\t" . v}))
    call append('$', ['Type your messages below, press C-] to send.  (Content of all buffers is shared alongside!)', '', 'You: '])

    " Fold the system prompt
    normal! 1Gzjzc

    call s:UpdateStatusRegion()

    augroup ClaudeChat
      autocmd!
      autocmd BufWinEnter <buffer> call s:GoToLastYouLine()
      exe printf('au BufEnter * if bufwinnr(%d) != -1 | call s:UpdateStatusRegion() | endif', bufnr())
      au BufUnload <buffer> ++once au! ClaudeChat| augroup! ClaudeChat
    augroup END

    " Add mappings for this buffer
    command! -buffer -nargs=1 SendChatMessage call s:SendChatMessage(<q-args>)
    execute "inoremap <buffer> " . g:claude_map_send_chat_message . " <Esc>:call <SID>SendChatMessage('Claude:')<CR>"
    execute "nnoremap <buffer> " . g:claude_map_send_chat_message . " :call <SID>SendChatMessage('Claude:')<CR>"
  else
    let l:claude_winid = bufwinid(l:claude_bufnr)
    if l:claude_winid == -1
      execute 'botright split'
      execute 'buffer' l:claude_bufnr
    else
      call win_gotoid(l:claude_winid)
    endif
  endif
  call s:GoToLastYouLine()
endfunction


" ============================================================================
" Chat parser (to messages list) {{{1
" ============================================================================

function! s:AddMessageToList(messages, message)
  " FIXME: Handle multiple tool_use, tool_result blocks at once
  if !empty(a:message.role)
    let l:message = {'role': a:message.role, 'content': join(a:message.content, "\n")}
    if !empty(a:message.tool_use)
      let l:message['content'] = [{'type': 'text', 'text': l:message.content}, a:message.tool_use]
    endif
    if !empty(a:message.tool_result)
      let l:message['content'] = [a:message.tool_result]
    endif
    call add(a:messages, l:message)
  endif
endfunction

" Messages have role, content text, and a tool-use, tool-result block
"" Drops the first word in line, since it is the role
function! s:InitMessage(role, line)
  return {
    \ 'role': a:role,
    \ 'content': [substitute(a:line, '^\S*\s*', '', '')],
    \ 'tool_use': {},
    \ 'tool_result': {}
  \ }
endfunction

function! s:ParseToolUse(line)
  let l:match = matchlist(a:line, '^Tool use (\(.*\)): \(.*\)$')
  if empty(l:match)
    return {}
  endif

  return {
    \ 'type': 'tool_use',
    \ 'id': l:match[1],
    \ 'name': l:match[2],
    \ 'input': {}
  \ }
endfunction

function! s:InitToolResult(line)
  let l:match = matchlist(a:line, '^Tool result (\(.*\)):')
  return {
    \ 'role': 'user',
    \ 'content': [],
    \ 'tool_use': {},
    \ 'tool_result': {
      \ 'type': 'tool_result',
      \ 'tool_use_id': l:match[1],
      \ 'content': ''
    \ }
  \ }
endfunction

function! s:AppendContent(message, line)
  let l:indent = s:GetClaudeIndent()
  if !empty(a:message.tool_use)
    if a:line =~ '^\s*Input:'
      let a:message.tool_use.input = json_decode(substitute(a:line, '^\s*Input:\s*', '', ''))
    elseif a:message.tool_use.name == 'python'
      if !has_key(a:message.tool_use.input, 'code')
        let a:message.tool_use.input.code = ''
      endif
      let a:message.tool_use.input.code .= (empty(a:message.tool_use.input.code) ? '' : "\n") . substitute(a:line, '^' . l:indent, '', '')
    endif
  elseif !empty(a:message.tool_result)
    let a:message.tool_result.content .= (empty(a:message.tool_result.content) ? '' : "\n") . substitute(a:line, '^' . l:indent, '', '')
  else
    call add(a:message.content, substitute(substitute(a:line, '^' . l:indent, '', ''), '\s*\[APPLIED\]$', '', ''))
  endif
endfunction

"" Closes the current message if line begins a new message
"" Adds line to the current message, truncating prefix
function! s:ProcessLine(line, messages, current_message)
  let l:new_message = copy(a:current_message)

  ""Unindented lines begin a new message, and the current message is saved
  "" Claude responses may include a tool use block
  "" Tool result appers as a user block with a tool_result annotation
  if a:line =~ '^You:'
    call s:AddMessageToList(a:messages, l:new_message)
    let l:new_message = s:InitMessage('user', a:line)
  elseif a:line =~ '^Claude'  " both Claude: and Claude...:
    call s:AddMessageToList(a:messages, l:new_message)
    let l:new_message = s:InitMessage('assistant', a:line)
  elseif a:line =~ '^Tool use ('
    let l:new_message.tool_use = s:ParseToolUse(a:line)
  elseif a:line =~ '^Tool result ('
    call s:AddMessageToList(a:messages, l:new_message)
    let l:new_message = s:InitToolResult(a:line)
  elseif !empty(l:new_message.role)
    call s:AppendContent(l:new_message, a:line)
  endif

  return l:new_message
endfunction

function! s:ParseChatBuffer()
  let l:buffer_content = getline(1, '$')
  let l:messages = []
  let l:current_message = {'role': '', 'content': [], 'tool_use': {}, 'tool_result': {}}
  let l:system_prompt = []
  let l:in_system_prompt = 0
  let l:in_top_status_region = 0

  "" The buffer consists of a system prompt followed by a set of messages
  "" Unindented text after the system prompt goes into a message with no role and is discarded
  for line in l:buffer_content
    if line =~ 'Included buffers \[[0-9]*]:'
      let l:in_top_status_region = 1
    elseif line =~ '^System prompt:'
      let l:in_system_prompt = 1
      let l:in_top_status_region = 0
      let l:system_prompt = [substitute(line, '^System prompt:\s*', '', '')]
    elseif l:in_top_status_region
      " Do nothing
    elseif l:in_system_prompt && line =~ '^\s'
      call add(l:system_prompt, substitute(line, '^\s*', '', ''))
    else
      let l:in_system_prompt = 0
      let l:current_message = s:ProcessLine(line, l:messages, l:current_message)
    endif
  endfor

  if !empty(l:current_message.role)
    call s:AddMessageToList(l:messages, l:current_message)
  endif

  return [filter(l:messages, {_, v -> !empty(v.content)}), join(l:system_prompt, "\n")]
endfunction


" ============================================================================
" Sending messages {{{1
" ============================================================================

function! s:GetBuffersContent()
  let l:buffers = []
  let [l:chat_bufnr, _, _] = s:GetOrCreateChatWindow()
  for bufnr in s:GetIncludedBuffers(l:chat_bufnr)
    let l:bufname = s:buf_displayname(bufnr)
    let l:contents = join(getbufline(bufnr, 1, '$'), "\n")
    call add(l:buffers, {
        \ 'name': l:bufname,
        \ 'lastmodified': s:GetBufTimestamp(bufnr),
        \ 'contents': l:contents
        \ })
  endfor
  return l:buffers
endfunction

function! s:SendChatMessage(prefix)
  " Parse the buffer into messages
  let [l:messages, l:system_prompt] = s:ParseChatBuffer()

  " If the last message has a tool use block
  let l:tool_uses = s:ResponseExtractToolUses(l:messages)
  if !empty(l:tool_uses)
    for l:tool_use in l:tool_uses
      let l:tool_result = s:ExecuteTool(l:tool_use.name, l:tool_use.input)
      call s:AppendToolResult(l:tool_use.id, l:tool_result)
    endfor
    let [l:messages, l:system_prompt] = s:ParseChatBuffer()
    call s:LogMessage("Messages after tool Result:" . string(l:messages))
  endif

  let l:buffer_contents = s:GetBuffersContent()
  call append('$', a:prefix . " ")
  normal! G

  let l:job = s:ClaudeQueryInternal(l:messages, l:buffer_contents, l:system_prompt, g:claude_tools, function('s:StreamingChatResponse'), function('s:FinalChatResponse'))

  " Store the job ID or channel for potential cancellation
  if has('nvim')
    let s:current_chat_job = l:job
  else
    let s:current_chat_job = job_getchannel(l:job)
  endif
endfunction


" Command to send message in normal mode
command! ClaudeSend call <SID>SendChatMessage('Claude:')


" ============================================================================
" Handling responses: Tool use {{{1
" ============================================================================

function! s:ResponseExtractToolUses(messages)
  if len(a:messages) == 0
    return []
  elseif type(a:messages[-1].content) == v:t_list
    return filter(copy(a:messages[-1].content), 'v:val.type == "tool_use"')
  else
    return []
  endif
endfunction

function! s:AppendToolUse(tool_call_id, tool_name, tool_input)
  let l:indent = s:GetClaudeIndent()
  " Ensure there's text content before the first tool use
  if getline('$') =~# '^Claude\.*: *$'
    call setline('$', 'Claude...: (tool-only response)')
  endif
  call append('$', 'Tool use (' . a:tool_call_id . '): ' . a:tool_name)
  if a:tool_name == 'python'
    for line in split(a:tool_input.code, "\n")
      call append('$', l:indent . line)
    endfor
  else
    call append('$', l:indent . 'Input: ' . json_encode(a:tool_input))
  endif
  normal! G
endfunction

function! s:AppendToolResult(tool_call_id, result)
  let l:indent = s:GetClaudeIndent()
  call append('$', 'Tool result (' . a:tool_call_id . '):')
  call append('$', map(split(a:result, "\n"), {_, v -> l:indent . v}))
  normal! G
endfunction


" ============================================================================
" Handling responses: Code changes {{{1
" ============================================================================

" FIXME: Want tests for this
function! s:ProcessCodeBlock(block, all_changes)
  let l:matches = matchlist(a:block.header, '^\(\S\+\)\s\+\([^:]\+\)\%(:\(.*\)\)\?$')
  let l:filetype = get(l:matches, 1, '')
  let l:buffername = get(l:matches, 2, '')
  let l:normal_command = get(l:matches, 3, '')

  if empty(l:buffername)
    echom "Warning: No buffer name specified in code block header"
    return
  endif

  let l:target_bufnr = bufnr(l:buffername)

  if l:target_bufnr == -1
    echom "Warning: Buffer not found for " . l:buffername
    return
  endif

  if !has_key(a:all_changes, l:target_bufnr)
    let a:all_changes[l:target_bufnr] = []
  endif

  if l:filetype ==# 'vimexec'
    call add(a:all_changes[l:target_bufnr], {
          \ 'type': 'vimexec',
          \ 'commands': a:block.code
          \ })
  else
    if empty(l:normal_command)
      " By default, append to the end of file
      let l:normal_command = 'Go<CR>'
    endif

    call add(a:all_changes[l:target_bufnr], {
          \ 'type': 'content',
          \ 'normal_command': l:normal_command,
          \ 'content': join(a:block.code, "\n")
          \ })
  endif

  " Mark the applied code block
  let l:indent = s:GetClaudeIndent()
  call setline(a:block.start_line - 1, l:indent . '```' . a:block.header . ' [APPLIED]')
endfunction

function! s:ResponseExtractChanges()
  let l:all_changes = {}

  " Find the start of the last Claude block
  normal! G
  let l:start_line = search('^Claude:', 'b')  " Skip over Claude...:
  let l:end_line = line('$')
  let l:markdown_delim = '^' . s:GetClaudeIndent() . '```'

  let l:in_code_block = 0
  let l:current_block = {'header': '', 'code': [], 'start_line': 0}

  for l:line_num in range(l:start_line, l:end_line)
    let l:line = getline(l:line_num)

    if l:line =~ l:markdown_delim
      if ! l:in_code_block
        " Start of code block
        let l:current_block = {'header': substitute(l:line, l:markdown_delim, '', ''), 'code': [], 'start_line': l:line_num + 1}
        let l:in_code_block = 1
      else
        " End of code block
        let l:current_block.end_line = l:line_num
        call s:ProcessCodeBlock(l:current_block, l:all_changes)
        let l:in_code_block = 0
      endif
    elseif l:in_code_block
      call add(l:current_block.code, substitute(l:line, '^' . s:GetClaudeIndent(), '', ''))
    endif
  endfor

  " Process any remaining open code block
  if l:in_code_block
    let l:current_block.end_line = l:end_line
    call s:ProcessCodeBlock(l:current_block, l:all_changes)
  endif

  return l:all_changes
endfunction

function s:ApplyChangesFromResponse()
  let l:all_changes = s:ResponseExtractChanges()
  if !empty(l:all_changes)
    for [l:target_bufnr, l:changes] in items(l:all_changes)
      call s:ApplyCodeChangesDiff(str2nr(l:target_bufnr), l:changes)
    endfor
  endif
  normal! G
endfunction


" ============================================================================
" Handling responses {{{1
" ============================================================================

function! s:ClosePreviousFold()
  let l:save_cursor = getpos(".")

  normal! G[zk[zzc

  if foldclosed('.') == -1
    echom "Warning: Failed to close previous fold at line " . line('.')
  endif

  call setpos('.', l:save_cursor)
endfunction

function! s:CloseCurrentInteractionCodeBlocks()
  let l:save_cursor = getpos(".")

  " Move to the start of the current interaction
  normal! [z

  " Find and close all level 2 folds until the end of the interaction
  while 1
    if foldlevel('.') == 2
      normal! zc
    endif

    let current_line = line('.')
    normal! j
    if line('.') == current_line || foldlevel('.') < 1 || line('.') == line('$')
      break
    endif
  endwhile

  call setpos('.', l:save_cursor)
endfunction

function! s:PrepareNextInput()
  call append('$', '')
  call append('$', 'You: ')
  normal! G$
endfunction

function! s:StreamingChatResponse(delta)
  let [l:chat_bufnr, l:chat_winid, l:current_winid] = s:GetOrCreateChatWindow()
  call win_gotoid(l:chat_winid)

  let l:indent = s:GetClaudeIndent()
  let l:new_lines = split(a:delta, "\n", 1)

  if len(l:new_lines) > 0
    " Update the last line with the first segment of the delta
    let l:last_line = getline('$')
    call setline('$', l:last_line . l:new_lines[0])

    call append('$', map(l:new_lines[1:], {_, v -> l:indent . v}))
  endif

  normal! G
  call win_gotoid(l:current_winid)
endfunction

function! s:FinalChatResponse()
  let [l:chat_bufnr, l:chat_winid, l:current_winid] = s:GetOrCreateChatWindow()
  let [l:messages, l:system_prompt] = s:ParseChatBuffer()
  call s:LogMessage("Final Chat Response:" . string(l:messages))
  let l:tool_uses = s:ResponseExtractToolUses(l:messages)

  call s:ApplyChangesFromResponse()

  if !empty(l:tool_uses)
    call s:SendChatMessage('Claude...:')
  else
    call s:ClosePreviousFold()
    call s:CloseCurrentInteractionCodeBlocks()
    call s:PrepareNextInput()
    call win_gotoid(l:current_winid)
    unlet! s:current_chat_job
  endif
endfunction

function! s:CancelClaudeResponse()
  if exists("s:current_chat_job")
    if has('nvim')
      call jobstop(s:current_chat_job)
    else
      call ch_close(s:current_chat_job)
    endif
    unlet s:current_chat_job
    call s:AppendResponse("[Response cancelled by user]")
    call s:ClosePreviousFold()
    call s:CloseCurrentInteractionCodeBlocks()
    call s:PrepareNextInput()
    echo "Claude response cancelled."
  else
    echo "No ongoing Claude response to cancel."
  endif
endfunction

" ============================================================================
" Test Harness {{{1
" ============================================================================

if g:claude_testing
  let claude#test = { 
    \ 'InflateMessageContent': function("s:InflateMessageContent"),
    \ 'ParseChatBuffer': function("s:ParseChatBuffer"),
    \ 'ResponseExtractToolUses': function("s:ResponseExtractToolUses"),
    \ 'GetBuffersContent': function("s:GetBuffersContent"),
    \ 'GetIncludedBuffers': function("s:GetIncludedBuffers"),
    \ 'ProcessCodeBlock': function("s:ProcessCodeBlock"),
    \ }

  call s:SetupClaudeKeybindings()
endif

