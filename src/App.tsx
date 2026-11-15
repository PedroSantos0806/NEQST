import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClient } from '@/lib/query-client'
import { Toaster } from '@/components/ui/sonner'
import { AuthProvider } from '@/features/auth/AuthProvider'
import { RequireAuth } from '@/features/auth/RequireAuth'
import { LoginPage } from '@/features/auth/LoginPage'
import { AppLayout } from '@/components/layout/AppLayout'
import { PagePlaceholder } from '@/components/layout/PagePlaceholder'

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<LoginPage />} />
            <Route element={<RequireAuth />}>
              <Route element={<AppLayout />}>
                <Route
                  index
                  element={
                    <PagePlaceholder
                      title="Funis"
                      sprint="Sprint 2"
                      description="Kanban dos 4 funis com arrastar e soltar, totais por coluna e alerta de parado."
                    />
                  }
                />
                <Route
                  path="contatos"
                  element={
                    <PagePlaceholder
                      title="Contatos"
                      sprint="Sprint 1"
                      description="Cadastro de contatos e leads, com empresa, cargo e ciclo de vida."
                    />
                  }
                />
                <Route
                  path="empresas"
                  element={
                    <PagePlaceholder
                      title="Empresas"
                      sprint="Sprint 1"
                      description="Operadores públicos, clubes, condomínios, construtoras e marcas."
                    />
                  }
                />
                <Route
                  path="locais"
                  element={
                    <PagePlaceholder
                      title="Locais"
                      sprint="Sprint 1"
                      description="Parques e unidades de cada empresa, com quadras, pisos e internet."
                    />
                  }
                />
                <Route
                  path="tarefas"
                  element={
                    <PagePlaceholder
                      title="Tarefas"
                      sprint="Sprint 3"
                      description="Minhas tarefas de hoje e próximas atividades dos negócios."
                    />
                  }
                />
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
