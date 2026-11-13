import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './app/App';
import './styles/app.css';
import { applyStoredTheme } from './lib/theme';
applyStoredTheme();
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
