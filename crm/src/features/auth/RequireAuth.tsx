import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from './auth-context'

export function RequireAuth() {
  const { session, loading } = useAuth()
  const location = useLocation()

  if (loading) {
    return (
      <div className="grid min-h-svh place-items-center font-display text-2xl tracking-wide text-primary">
        Carregando…
      </div>
    )
  }
  if (!session) return <Navigate to="/login" replace state={{ from: location.pathname }} />
  return <Outlet />
}
