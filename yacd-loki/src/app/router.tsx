import { Suspense } from 'react';
import { HashRouter, Navigate, RouteObject, useRoutes } from 'react-router-dom';

import SideBar from '~/app/SideBar';
import Loading from '~/components/shared/Loading';

import styles from '../App.module.scss';
import ConnectionsPage from '../pages/ConnectionsPage';
import HomePage from '../pages/HomePage';
import LogsPage from '../pages/LogsPage';
import ProxiesPage from '../pages/ProxiesPage';
import RulesPage from '../pages/RulesPage';
import StyleGuidePage from '../pages/StyleGuidePage';

const routes = [
  { path: '/', element: <Navigate to="/proxies" replace /> },
  { path: '/home', element: <HomePage /> },
  { path: '/connections', element: <ConnectionsPage /> },
  { path: '/logs', element: <LogsPage /> },
  { path: '/proxies', element: <ProxiesPage /> },
  { path: '/rules', element: <RulesPage /> },
  import.meta.env.DEV ? { path: '/style', element: <StyleGuidePage /> } : false,
].filter(Boolean) as RouteObject[];

function DashboardRouter() {
  return (
    <>
      <SideBar />
      <div className={styles.content}>{useRoutes(routes)}</div>
    </>
  );
}

export function AppRouter() {
  return (
    <div className={styles.app}>
      <Suspense fallback={<Loading />}>
        <HashRouter>
          <DashboardRouter />
        </HashRouter>
      </Suspense>
    </div>
  );
}
