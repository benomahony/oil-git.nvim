local M = {}

-- Default highlight colors (only used if not already defined)
local default_highlights = {
  OilGitAdded = { fg = "#a6e3a1" },
  OilGitModified = { fg = "#f9e2af" },
  OilGitRenamed = { fg = "#cba6f7" },
  OilGitUntracked = { fg = "#89b4fa" },
  OilGitIgnored = { fg = "#6c7086" },
}


local function setup_highlights()
  -- Only set highlight if it doesn't already exist (respects colorscheme)
  for name, opts in pairs(default_highlights) do
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
end

local symbols = {
  OilGitAdded = "+",
  OilGitModified = "~",
  OilGitRenamed = "→",
  OilGitUntracked = "?",
  OilGitIgnored = "!",
}

---@param user_symbols table A potentially incomplete config of symbols
local function setup_symbols(user_symbols)
  symbols.OilGitAdded = user_symbols.OilGitAdded or "+"
  symbols.OilGitModified = user_symbols.OilGitModified or "~"
  symbols.OilGitRenamed = user_symbols.OilGitRenamed or "→"
  symbols.OilGitUntracked = user_symbols.OilGitUntracked or "?"
  symbols.OilGitIgnored = user_symbols.OilGitIgnored or "!"
end

local function get_git_root(path)
  local git_dir = vim.fn.finddir(".git", path .. ";")
  if git_dir == "" then
    return nil
  end
  -- Get the parent directory of .git, not .git itself
  return vim.fn.fnamemodify(git_dir, ":p:h:h")
end

local function get_git_status(dir)
  local git_root = get_git_root(dir)
  if not git_root then
    return {}
  end

  local cmd = string.format("cd %s && git status --porcelain --ignored", vim.fn.shellescape(git_root))
  local output = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    return {}
  end

  local status = {}
  for line in output:gmatch("[^\r\n]+") do
    if #line >= 3 then
      local status_code = line:sub(1, 2)
      local filepath = line:sub(4)

      -- Handle renames (format: "old-name -> new-name")
      if status_code:sub(1, 1) == "R" then
        local arrow_pos = filepath:find(" %-> ")
        if arrow_pos then
          filepath = filepath:sub(arrow_pos + 4)
        end
      end

      -- Remove leading "./" if present
      if filepath:sub(1, 2) == "./" then
        filepath = filepath:sub(3)
      end

      -- Convert to absolute path
      local abs_path = git_root .. "/" .. filepath

      status[abs_path] = status_code
    end
  end

  return status
end

local function get_highlight_group(status_code)
  if not status_code then
    return nil, nil
  end

  local first_char = status_code:sub(1, 1)
  local second_char = status_code:sub(2, 2)

  -- Check staged changes first (prioritize staged over unstaged)
  if first_char == "A" then
    return "OilGitAdded", symbols.OilGitAdded
  elseif first_char == "M" then
    return "OilGitModified", symbols.OilGitModified
  elseif first_char == "R" then
    return "OilGitRenamed", symbols.OilGitRenamed
  end

  -- Check unstaged changes
  if second_char == "M" then
    return "OilGitModified", symbols.OilGitModified
  end

  -- Untracked files
  if status_code == "??" then
    return "OilGitUntracked", symbols.OilGitUntracked
  end

  -- Ignored files
  if status_code == "!!" then
    return "OilGitIgnored", symbols.OilGitIgnored
  end

  return nil, nil
end

local function clear_highlights()
  -- Clear existing git highlights and virtual text
  for name, _ in pairs(default_highlights) do
    vim.fn.clearmatches()
  end

  -- Clear existing virtual text
  local ns_id = vim.api.nvim_create_namespace("oil_git_status")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
end

local function apply_git_highlights()
  local oil = require("oil")
  local current_dir = oil.get_current_dir()

  if not current_dir then
    clear_highlights()
    return
  end

  local git_status = get_git_status(current_dir)
  if vim.tbl_isempty(git_status) then
    clear_highlights()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  clear_highlights()

  for i, line in ipairs(lines) do
    local entry = oil.get_entry_on_line(bufnr, i)
    if entry and entry.type == "file" then
      local filepath = current_dir .. entry.name

      local status_code = git_status[filepath]
      local hl_group, symbol = get_highlight_group(status_code)

      if hl_group and symbol then
        -- Find the filename part in the line and highlight it
        local name_start = line:find(entry.name, 1, true)
        if name_start then
          -- Highlight the filename
          vim.fn.matchaddpos(hl_group, { { i, name_start, #entry.name } })

          -- Add symbol as virtual text at the end of the line
          local ns_id = vim.api.nvim_create_namespace("oil_git_status")
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
            virt_text = { { " " .. symbol, hl_group } },
            virt_text_pos = "eol",
          })
        end
      end
    end
  end
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("OilGitStatus", { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "oil://*",
    callback = function()
      vim.schedule(apply_git_highlights)
    end,
  })

  -- Clear highlights when leaving oil buffers
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    pattern = "oil://*",
    callback = clear_highlights,
  })

  -- Refresh when oil buffer content changes (file operations)
  vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "oil://*",
    callback = function()
      vim.schedule(apply_git_highlights)
    end,
  })

  -- Multiple events to catch lazygit closure
  vim.api.nvim_create_autocmd({ "FocusGained", "WinEnter", "BufWinEnter" }, {
    group = group,
    pattern = "oil://*",
    callback = function()
      vim.schedule(apply_git_highlights)
    end,
  })

  -- Terminal events (for when lazygit closes)
  vim.api.nvim_create_autocmd("TermClose", {
    group = group,
    callback = function()
      vim.schedule(function()
        if vim.bo.filetype == "oil" then
          apply_git_highlights()
        end
      end)
    end,
  })

  -- Also catch common git-related user events
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "FugitiveChanged", "GitSignsUpdate", "LazyGitClosed" },
    callback = function()
      if vim.bo.filetype == "oil" then
        vim.schedule(apply_git_highlights)
      end
    end,
  })
end

-- Track if plugin has been initialized
local initialized = false

local function initialize()
  if initialized then
    return
  end

  setup_highlights()
  setup_autocmds()
  initialized = true
end

function M.setup(opts)
  opts = opts or {}

  -- Merge user highlights with defaults (only affects fallbacks)
  if opts.highlights then
    default_highlights = vim.tbl_extend("force", default_highlights, opts.highlights)
  end

  -- Set user symbols
  if opts.symbols then
    setup_symbols(opts.symbols)
  end

  initialize()
end

-- Auto-initialize when oil buffer is entered (if not already done)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "oil",
  callback = function()
    initialize()
  end,
  group = vim.api.nvim_create_augroup("OilGitAutoInit", { clear = true }),
})

-- Manual refresh function
function M.refresh()
  apply_git_highlights()
end

return M
