export const metadata = { title: 'No account' };

export default function NoAccount() {
  return (
    <div className="center-page">
      <div className="card">
        <h1>Your account isn’t set up</h1>
        <p className="muted">You are signed in, but TeamPulse has no active employee record for you. Please ask PEACE’s admin to add or re-activate you.</p>
        <form action="/sign-out" method="post"><button className="btn secondary">Sign out</button></form>
      </div>
    </div>
  );
}
