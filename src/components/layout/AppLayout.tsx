import { NavLink, Outlet } from 'react-router-dom'
import { Building2, CheckSquare, Columns3, LogOut, MapPin, Users } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useAuth } from '@/features/auth/auth-context'
import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'

const NAV = [
  { to: '/', label: 'Funis', icon: Columns3, end: true },
  { to: '/contatos', label: 'Contatos', icon: Users },
  { to: '/empresas', label: 'Empresas', icon: Building2 },
  { to: '/locais', label: 'Locais', icon: MapPin },
  { to: '/tarefas', label: 'Tarefas', icon: CheckSquare },
]

function initials(text: string) {
  return text
    .split(/[\s@.]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase())
    .join('')
}

export function AppLayout() {
  const { user, signOut } = useAuth()
  const name = (user?.user_metadata?.full_name as string | undefined) ?? user?.email ?? ''
  const avatarUrl = user?.user_metadata?.avatar_url as string | undefined

  return (
    <div className="flex min-h-svh flex-col md:flex-row">
      <aside className="flex shrink-0 items-center gap-2 bg-sidebar px-4 py-2 text-sidebar-foreground md:w-56 md:flex-col md:items-stretch md:px-3 md:py-5">
        <span className="font-display text-3xl leading-none tracking-wider text-sidebar-primary md:mb-6 md:px-2">
          NEQST
        </span>
        <nav className="flex flex-1 gap-1 overflow-x-auto md:flex-col md:overflow-visible">
          {NAV.map(({ to, label, icon: Icon, end }) => (
            <NavLink
              key={to}
              to={to}
              end={end}
              className={({ isActive }) =>
                cn(
                  'flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm font-medium whitespace-nowrap transition-colors',
                  isActive
                    ? 'bg-sidebar-primary text-sidebar-primary-foreground'
                    : 'text-sidebar-foreground/85 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground',
                )
              }
            >
              <Icon className="size-4" aria-hidden />
              <span className="hidden sm:inline">{label}</span>
            </NavLink>
          ))}
        </nav>
        <DropdownMenu>
          <DropdownMenuTrigger
            className="flex items-center gap-2 rounded-lg p-1.5 text-left text-sm outline-none hover:bg-sidebar-accent focus-visible:ring-2 focus-visible:ring-sidebar-ring md:p-2"
            aria-label="Menu da conta"
          >
            <Avatar className="size-7">
              {avatarUrl && <AvatarImage src={avatarUrl} alt="" />}
              <AvatarFallback className="bg-sidebar-primary text-xs text-sidebar-primary-foreground">
                {initials(name)}
              </AvatarFallback>
            </Avatar>
            <span className="hidden min-w-0 truncate md:block">{name}</span>
          </DropdownMenuTrigger>
          <DropdownMenuContent side="top" align="start" className="min-w-52">
            <DropdownMenuLabel className="truncate">{user?.email}</DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={() => void signOut()}>
              <LogOut className="size-4" aria-hidden />
              Sair
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </aside>
      <main className="min-w-0 flex-1 p-4 md:p-8">
        <Outlet />
      </main>
    </div>
  )
}
