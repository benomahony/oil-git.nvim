-- Auto-initialize oil-git.nvim when oil buffer is opened
local ok, oil_git = pcall(require, "oil-git")
if ok then
        -- Initialize without calling setup (uses defaults)
        oil_git.setup()
end
