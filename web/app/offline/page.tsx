export const metadata = { title: 'Offline' };

export default function Offline() {
  return (
    <div className="center-page">
      <div className="card">
        <img className="logo-big" src="/icons/icon-192.png" alt="" />
        <h1>You are offline</h1>
        <p className="muted">TeamPulse needs a connection to show your time, leave and payslips. They are never stored on this device.</p>      </div>
    </div>
  );
}
