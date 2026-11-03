export const metadata = { title: 'Offline' };

export default function Offline() {
  return (
    <div className="center-page">
      <div className="card">
        <img className="logo-wordmark" src="/icons/logo.png" alt="Team Nepal Solutions" />
        <h1>You are offline</h1>
        <p className="muted">TeamPulse needs a connection to show your time, leave and payslips. They are never stored on this device.</p>      </div>
    </div>
  );
}
