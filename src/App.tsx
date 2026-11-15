import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClient } from '@/lib/query-client'
import { Toaster } from '@/components/ui/sonner'
import { AuthProvider } from '@/features/auth/AuthProvider'
import { RequireAuth } from '@/features/auth/RequireAuth'
import { LoginPage } from '@/features/auth/LoginPage'
import { AppLayout } from '@/components/layout/AppLayout'
import { CompaniesPage } from '@/features/companies/CompaniesPage'
import { CompanyDetailPage } from '@/features/companies/CompanyDetailPage'
import { LocationsPage } from '@/features/locations/LocationsPage'
import { ContactsPage } from '@/features/contacts/ContactsPage'
import { BoardPage } from '@/features/deals/BoardPage'
import { DealDetailPage } from '@/features/deals/DealDetailPage'
import { TasksPage } from '@/features/activities/TasksPage'

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<LoginPage />} />
            <Route element={<RequireAuth />}>
              <Route element={<AppLayout />}>
                <Route index element={<BoardPage />} />
                <Route path="contatos" element={<ContactsPage />} />
                <Route path="empresas" element={<CompaniesPage />} />
                <Route path="empresas/:id" element={<CompanyDetailPage />} />
                <Route path="locais" element={<LocationsPage />} />
                <Route path="tarefas" element={<TasksPage />} />
                <Route path="negocios/:id" element={<DealDetailPage />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Route>
            </Route>
          </Routes>
        </BrowserRouter>
      </AuthProvider>
      <Toaster position="top-right" />
    </QueryClientProvider>
  )
}
