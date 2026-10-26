const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  load: () => ipcRenderer.invoke('data:load'),
  save: (json) => ipcRenderer.invoke('data:save', json),
  getSecret: (k) => ipcRenderer.invoke('secret:get', k),
  setSecret: (k, v) => ipcRenderer.invoke('secret:set', k, v),
  chat: (req) => ipcRenderer.invoke('llm:chat', req),
  models: (req) => ipcRenderer.invoke('llm:models', req),
  copyHTML: (html, text) => ipcRenderer.invoke('clip:html', html, text),
  copyText: (text) => ipcRenderer.invoke('clip:text', text),
  login: (acc) => ipcRenderer.invoke('acc:login', acc),
  fill: (req) => ipcRenderer.invoke('acc:fill', req),
  openURL: (u) => ipcRenderer.invoke('open:url', u),
  env: () => ipcRenderer.invoke('env'),
  shotDone: () => ipcRenderer.invoke('shot:done'),
  shot: (name) => ipcRenderer.invoke('shot:take', name),
})
