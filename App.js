import React from "react";
import Head from "next/head";
import Modal from "react-modal";
import { ParallaxProvider } from "react-scroll-parallax";
import { AuthProvider } from "../context/AuthContext";
import { WalletProvider } from "../context/WalletContext";
import { UserProvider } from "../context/UserContext";
import { NotificationProvider } from "../context/NotificationContext";
import { ProjectProvider } from "../context/ProjectContext";
import { ScrollProvider } from "../context/ScrollContext";
import { GlobalModalProvider } from "../context/ModalContext";
import Header from "../src/components/Header/Header";
import "../styles/globalStyles.css";

Modal.setAppElement("#__next");

function MyApp({ Component, pageProps }) {
  return (
    <ParallaxProvider>
      <AuthProvider>
        <WalletProvider>
          <UserProvider>
            <NotificationProvider>
              <GlobalModalProvider>
                <ProjectProvider>
                  <ScrollProvider>
                    <div>
                      <Head>
                        <title>Paxmata</title>
                        <meta name="description" content="Project Management" />
                        {/* Standard favicon */}
                        <link
                          rel="icon"
                          type="image/png"
                          sizes="32x32"
                          href="/images/Logo without words.png"
                        />
                        <link
                          rel="icon"
                          type="image/png"
                          sizes="16x16"
                          href="/images/Logo without words.png"
                        />
                        {/* Apple Touch Icon */}
                        <link
                          rel="apple-touch-icon"
                          sizes="180x180"
                          href="/images/Logo without words.png"
                        />
                        {/* Optional: Add manifest for PWA support */}
                        <link rel="manifest" href="/site.webmanifest" />
                        {/* Optional: Add IE/Edge support */}
                        <meta
                          name="msapplication-TileColor"
                          content="#ffffff"
                        />
                        <meta name="theme-color" content="#ffffff" />
                      </Head>
                      <Header />
                      <main>
                        <Component {...pageProps} />
                      </main>
                    </div>
                  </ScrollProvider>
                </ProjectProvider>
              </GlobalModalProvider>
            </NotificationProvider>
          </UserProvider>
        </WalletProvider>
      </AuthProvider>
    </ParallaxProvider>
  );
}

export default MyApp;
