import logo from '@/assets/logo.png';
import { cn } from '@/shared/lib/cn';

interface AppLogoProps {
  className?: string;
}

/** The Kavach shield mark — one source (`assets/logo.png`, cut from the macOS
 * app icon) for the sidebar, welcome screen and launch splash. Decorative: the
 * app name always sits beside it as text. */
export const AppLogo = ({ className }: AppLogoProps) => (
  <img src={logo} alt="" draggable={false} className={cn('select-none', className)} />
);
