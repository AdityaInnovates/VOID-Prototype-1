const code = document.getElementById('code');
const status = document.getElementById('status');

chrome.storage.local.get(['token', 'status']).then(({ token, status: text }) => {
  code.value = token || '';
  status.textContent = text || 'Not connected yet';
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.status) status.textContent = changes.status.newValue;
});

document.getElementById('save').addEventListener('click', async () => {
  await chrome.storage.local.set({ token: code.value.trim().toUpperCase(), status: 'Connecting…' });
  chrome.runtime.sendMessage({ type: 'reconnect' });
});
