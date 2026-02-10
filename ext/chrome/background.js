// Available Chrome tab group colors, assigned round-robin per workspace
var COLORS = ['blue', 'red', 'yellow', 'green', 'pink', 'purple', 'cyan', 'orange'];

// workspace name -> { groupId, color }
var workspaceGroups = {};
var colorIndex = 0;

function nextColor() {
  var color = COLORS[colorIndex % COLORS.length];
  colorIndex++;
  return color;
}

// Find an existing tab group by title, or return null
async function findGroupByTitle(title, windowId) {
  var groups = await chrome.tabGroups.query({ windowId: windowId });
  for (var g of groups) {
    if (g.title === title) return g;
  }
  return null;
}

async function groupTab(tabId, workspace) {
  var tab = await chrome.tabs.get(tabId);
  var windowId = tab.windowId;

  // Check if we already track this workspace's group (and it still exists)
  var cached = workspaceGroups[workspace];
  if (cached) {
    try {
      var existing = await chrome.tabGroups.get(cached.groupId);
      if (existing) {
        await chrome.tabs.group({ tabIds: [tabId], groupId: cached.groupId });
        return;
      }
    } catch (_) {
      // Group was closed, fall through to create/find
    }
  }

  // Check if a group with this title already exists in the window
  var found = await findGroupByTitle(workspace, windowId);
  if (found) {
    workspaceGroups[workspace] = { groupId: found.id, color: found.color };
    await chrome.tabs.group({ tabIds: [tabId], groupId: found.id });
    return;
  }

  // Create a new group
  var color = nextColor();
  var groupId = await chrome.tabs.group({ tabIds: [tabId], createProperties: { windowId: windowId } });
  await chrome.tabGroups.update(groupId, { title: workspace, color: color });
  workspaceGroups[workspace] = { groupId: groupId, color: color };
}

chrome.runtime.onMessage.addListener(function (msg, sender) {
  if (msg.type === 'hatch-group' && msg.workspace && sender.tab) {
    groupTab(sender.tab.id, msg.workspace);
  }
});
