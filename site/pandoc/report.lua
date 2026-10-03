-- Rewrites repository-relative links to canonical GitHub links and makes
-- tables keyboard-scrollable. Metadata: repo-dir (the report's directory in the
-- repository, no trailing slash) and repo-url (e.g. https://github.com/OWNER/REPO).

local function split(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
  return parts
end

local function normalise(base, target)
  local out = split(base)
  for _, seg in ipairs(split(target)) do
    if seg == ".." then
      if #out == 0 then error("link escapes the repository: " .. target) end
      out[#out] = nil
    elseif seg ~= "." then
      out[#out + 1] = seg
    end
  end
  return out
end

function Pandoc(doc)
  local base = pandoc.utils.stringify(doc.meta["repo-dir"])
  local repo = pandoc.utils.stringify(doc.meta["repo-url"])
  -- A report may repeat its title as a second identical H1; keep the first.
  local seen = {}
  local blocks = pandoc.List()
  for _, b in ipairs(doc.blocks) do
    local drop = false
    if b.t == "Header" and b.level == 1 then
      local text = pandoc.utils.stringify(b)
      drop = seen[text] == true
      seen[text] = true
    end
    if not drop then blocks:insert(b) end
  end
  doc.blocks = blocks
  return doc:walk({
    Link = function(link)
      local t = link.target
      if t == "" or t:match("^#") or t:match("^%a[%w+.-]*:") or t:match("^/") then return nil end
      local path, frag = t:match("^([^#]*)(#?.*)$")
      path = path:gsub("%?.*$", "")
      local parts = normalise(base, path)
      local last = parts[#parts] or ""
      local kind = last:find("%.") and "blob" or "tree"
      link.target = repo .. "/" .. kind .. "/main/" .. table.concat(parts, "/") .. frag
      return link
    end,
    Table = function(tbl)
      return pandoc.Div({ tbl }, pandoc.Attr("", { "table-wrap" },
        { { "tabindex", "0" }, { "role", "region" }, { "aria-label", "Table, scrollable" } }))
    end,
  })
end
